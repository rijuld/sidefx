# frozen_string_literal: true

require "test_helper"
require "socket"

class ReceiptTest < Minitest::Test
  include SidefxTestHelpers

  def place_order(qty: 2)
    order = Order.new(user: @user)
    order.line_items.build(sku: "A", qty: qty)
    order.save!
    order
  end

  def test_writes_per_table_including_counter_cache
    r = Sidefx.receipt { place_order }
    assert_equal({ "orders" => 1, "line_items" => 1, "users" => 1 }, r.writes)
    assert_equal ["INSERT orders", "UPDATE users", "INSERT line_items"], r.committed.select { |e| e.kind == :write }.map(&:label)
  end

  def test_after_commit_job_and_where_it_came_from
    r = Sidefx.receipt { place_order }
    assert_equal ["FulfillmentJob"], r.jobs
    job = r.committed.find { |e| e.kind == :job }
    assert_match %r{\Atest/test_helper\.rb:\d+\z}, job.location
  end

  def test_callbacks_list_declared_ones_with_source
    r = Sidefx.receipt { place_order }
    save = r.callbacks[["Order", :save]]
    assert_equal 1, save.runs
    assert_equal ["before_save :compute_total"], save.declared.map(&:label)
    commit = r.callbacks[["Order", :commit]]
    assert_equal ["after_commit :fulfill"], commit.declared.map(&:label)
    assert commit.declared.first.conditional, "if: :persisted? should be flagged"
  end

  def test_mail_now_and_later_use_the_same_name
    order = place_order
    r = Sidefx.receipt do
      OrderMailer.receipt(order).deliver_now
      OrderMailer.receipt(order).deliver_later
    end
    assert_equal ["OrderMailer#receipt", "OrderMailer#receipt"], r.mails
    assert_equal %i[deliver_now deliver_later], r.committed.select { |e| e.kind == :mail }.map { |e| e.detail[:via] }
    assert_empty r.jobs, "MailDeliveryJob is reported as mail, not as a job"
  end

  def test_rollback_is_reported_separately
    r = Sidefx.receipt do
      AuditLog.transaction do
        AuditLog.create!(message: "kept?")
        raise ActiveRecord::Rollback
      end
      AuditLog.create!(message: "kept")
    end
    assert_equal({ "audit_logs" => 1 }, r.writes)
    assert_equal ["INSERT audit_logs"], r.rolled_back.map(&:label)
    assert_equal 1, AuditLog.count
  end

  def test_rollback_does_not_undo_mail_or_jobs
    order = place_order
    r = Sidefx.receipt do
      Order.transaction do
        AuditLog.create!(message: "charged")
        OrderMailer.receipt(order).deliver_now
        FulfillmentJob.perform_later(order.id)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal ["INSERT audit_logs"], r.rolled_back.map(&:label)
    assert_equal ["OrderMailer#receipt"], r.mails, "the email was really sent"
    assert_equal ["FulfillmentJob"], r.jobs
    assert_equal ["OrderMailer#receipt", "FulfillmentJob"], r.escaped_rollback.map(&:label)
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_includes r.to_s, "ran inside a transaction that rolled back"
  end

  def test_only_the_inner_savepoint_is_rolled_back
    r = Sidefx.receipt do
      AuditLog.transaction do
        AuditLog.create!(message: "outer")
        AuditLog.transaction(requires_new: true) do
          User.create!(name: "inner")
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal({ "audit_logs" => 1 }, r.writes)
    assert_equal ["INSERT users"], r.rolled_back.map(&:label)
  end

  def test_rollback_inside_a_transactional_test_wrapper
    # Rails' transactional tests open a non-joinable transaction first;
    # app transactions then become savepoints.
    ActiveRecord::Base.transaction(joinable: false) do
      User.first # materialize the outer transaction, as fixtures do
      r = Sidefx.receipt do
        AuditLog.transaction do
          AuditLog.create!(message: "x")
          raise ActiveRecord::Rollback
        end
      end
      assert_empty r.writes
      assert_equal ["INSERT audit_logs"], r.rolled_back.map(&:label)
      raise ActiveRecord::Rollback
    end
  end

  def test_n_plus_one_reads
    3.times { |i| User.create!(name: "u#{i}").orders.create! }
    r = Sidefx.receipt { User.all.each { |u| u.orders.to_a } }
    assert r.pure?
    shape, table, n = r.n_plus_ones.first
    assert_equal "orders", table
    assert_equal 4, n
    refute_match(/\d/, shape.sub("LIMIT ?", ""), "literals are normalized")
  end

  def test_cache_and_broadcasts
    cache = ActiveSupport::Cache::MemoryStore.new
    r = Sidefx.receipt do
      cache.write("stats", 1)
      cache.read("stats")
      cache.delete("stats")
      ActionCable.server.broadcast("orders", { id: 1 })
    end
    assert_equal ["write stats", "delete stats"], r.cache
    assert_equal ["orders"], r.broadcasts
  end

  def test_http_through_net_http
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.gets
      while (line = client.gets) && line != "\r\n"; end
      client.write("HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      client.close
    end
    r = Sidefx.receipt { Net::HTTP.post(URI("http://127.0.0.1:#{port}/v1/charges?x=1"), "amount=5") }
    thread.join
    assert_equal ["POST 127.0.0.1:#{port}/v1/charges"], r.http
    assert_equal "201", r.committed.first.detail[:status]
  ensure
    server&.close
  end

  def test_other_threads_do_not_leak_in
    cache = ActiveSupport::Cache::MemoryStore.new
    r = Sidefx.receipt do
      Thread.new do
        cache.write("elsewhere", 1)
        FulfillmentJob.perform_later(1)
      end.join
      User.create!(name: "here")
    end
    assert_equal({ "users" => 1 }, r.writes)
    assert_empty r.cache
    assert_empty r.jobs
  end

  def test_nested_receipts
    inner = nil
    outer = Sidefx.receipt do
      User.create!(name: "a")
      inner = Sidefx.receipt { AuditLog.create!(message: "b") }
    end
    assert_equal({ "audit_logs" => 1 }, inner.writes)
    assert_equal({ "users" => 1, "audit_logs" => 1 }, outer.writes)
  end

  def test_exceptions_propagate_and_print_still_prints
    out = StringIO.new
    assert_raises(RuntimeError) do
      Sidefx.print("boom", io: out) do
        User.create!(name: "before the crash")
        raise "boom"
      end
    end
    assert_includes out.string, "INSERT users"
    refute Sidefx::Recorder.active?
  end

  def test_value_and_pure
    r = Sidefx.receipt { 42 }
    assert_equal 42, r.value
    assert r.pure?
    assert_includes r.to_s, "NO SIDE EFFECTS"
  end

  def test_printed_receipt
    text = Sidefx.receipt("checkout") { place_order }.to_s
    assert_includes text, "S I D E F X"
    assert_match(/INSERT orders \.+ 1 row/, text)
    assert_includes text, "before_save :compute_total"
    assert_match(/TOTAL SIDE EFFECTS \.+ 4/, text)
  end

  def test_summary
    r = Sidefx.receipt { place_order }
    assert_match(/\A3 rows written \(orders, users, line_items\), 1 job · \d+ reads · [\d.]+ ms\z/, r.summary)
  end
end
