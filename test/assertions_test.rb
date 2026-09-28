# frozen_string_literal: true

require "test_helper"
require "rspec/expectations"
require "sidefx/rspec"
require "sidefx/middleware"
require "rack/mock"

class AssertionsTest < Minitest::Test
  include SidefxTestHelpers

  def test_passing_assertion_returns_receipt
    r = assert_side_effects(writes: { users: 1 }, jobs: 0, mails: 0) { User.create!(name: "x") }
    assert_kind_of Sidefx::Receipt, r
  end

  def test_failure_message_is_the_receipt
    err = assert_raises(Minitest::Assertion) do
      assert_side_effects(writes: { users: 1 }) do
        User.create!(name: "x")
        AuditLog.create!(message: "surprise")
      end
    end
    assert_includes err.message, "writes: audit_logs expected 0, got 1"
    assert_includes err.message, "S I D E F X"
  end

  def test_lists_regexps_and_counts
    assert_side_effects(jobs: [/Fulfill/], writes: 3) do
      o = Order.new(user: @user)
      o.save!
      FulfillmentJob.perform_later(1)
    end.then { |r| assert_equal 2, r.jobs.size }
  rescue Minitest::Assertion => e
    assert_includes e.message, "unexpected \"FulfillmentJob\""
  end

  def test_unknown_key
    assert_raises(ArgumentError) { assert_side_effects(emails: 1) { nil } }
  end

  def test_no_side_effects
    assert_no_side_effects { User.count }
    err = assert_raises(Minitest::Assertion) { assert_no_side_effects { User.create!(name: "x") } }
    assert_includes err.message, "INSERT users"
  end

  include RSpec::Matchers
  include Sidefx::RSpecMatchers # what `require "sidefx/rspec"` does via RSpec.configure

  def test_rspec_matcher
    expect { User.create!(name: "x") }.to have_side_effects(writes: { users: 1 })
    expect { User.count }.not_to have_side_effects
    expect { User.create!(name: "y") }.to have_side_effects
    expect do
      expect { User.count }.to have_side_effects(writes: { users: 1 })
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /users expected 1, got 0/)
  end

  def test_middleware_warns_on_writes_in_get
    log = StringIO.new
    app = ->(_env) { AuditLog.create!(message: "viewed"); [200, {}, ["ok"]] }
    mw = Sidefx::Middleware.new(app, logger: Logger.new(log))
    Rack::MockRequest.new(mw).get("/dashboard")
    assert_includes log.string, "GET /dashboard is a safe method but changed things"
    assert_includes log.string, "INSERT audit_logs"

    log.truncate(0)
    Rack::MockRequest.new(mw).post("/logs")
    assert_empty log.string, "POST writes are expected"
  end

  def test_middleware_log_mode
    log = StringIO.new
    mw = Sidefx::Middleware.new(->(_env) { User.count; [200, {}, ["ok"]] }, mode: :log, logger: Logger.new(log))
    Rack::MockRequest.new(mw).get("/")
    assert_match %r{\[sidefx\] GET / → no side effects · 1 reads}, log.string
  end
end
