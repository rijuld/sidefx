# frozen_string_literal: true

module Sidefx
  # One thing the code did to the world outside the Ruby process.
  #
  # kind     - :write, :job, :mail, :http, :broadcast or :cache
  # label    - what a person would call it: "INSERT orders", "OrderMailer#receipt"
  # count    - rows, keys or calls
  # location - "app/models/order.rb:12", the first frame in your code
  Effect = Struct.new(:kind, :label, :detail, :count, :location, :rolled_back, keyword_init: true) do
    def rolled_back?
      rolled_back == true
    end
  end

  Read = Struct.new(:table, :shape, :location, keyword_init: true)

  # A callback chain that ran on a model, with the callbacks declared in your code.
  CallbackRun = Struct.new(:model, :kind, :runs, :declared, keyword_init: true)

  # Everything a block did. Build one with Sidefx.receipt { ... }.
  class Receipt
    KINDS = %i[write job mail http broadcast cache].freeze
    N_PLUS_ONE_THRESHOLD = 3

    attr_reader :title, :effects, :reads, :callbacks
    attr_accessor :duration_ms, :error

    def initialize(title = nil)
      @title = title
      @effects = []
      @reads = []
      @callbacks = {}
      @duration_ms = 0.0
    end

    # Effects that really happened (not undone by a rollback).
    def committed
      effects.reject(&:rolled_back?)
    end

    def rolled_back
      effects.select(&:rolled_back?)
    end

    # Non-database effects made inside a transaction that rolled back: the
    # rows vanished, but these still happened (an email, a charge, a job).
    def escaped_rollback
      committed.select { |e| e.detail[:inside_rollback] }
    end

    # { "orders" => 1, "users" => 1 }: rows written per table, committed only.
    def writes
      committed.select { |e| e.kind == :write }.each_with_object(Hash.new(0)) do |e, h|
        h[e.detail[:table]] += e.count
      end
    end

    def jobs
      committed.select { |e| e.kind == :job }.map(&:label)
    end

    def mails
      committed.select { |e| e.kind == :mail }.map(&:label)
    end

    def http
      committed.select { |e| e.kind == :http }.map(&:label)
    end

    def broadcasts
      committed.select { |e| e.kind == :broadcast }.map(&:label)
    end

    def cache
      committed.select { |e| e.kind == :cache }.map(&:label)
    end

    # Read queries that repeated with the same shape, the classic N+1.
    # Returns [[shape, table, count], ...], worst first.
    def n_plus_ones
      reads.group_by(&:shape)
           .select { |_, rs| rs.size >= N_PLUS_ONE_THRESHOLD }
           .map { |shape, rs| [shape, rs.first.table, rs.size] }
           .sort_by { |(_, _, n)| -n }
    end

    # True when nothing outside the process changed. Reads don't count.
    def pure?
      committed.empty?
    end

    def count(kind = nil)
      kind ? committed.count { |e| e.kind == kind } : committed.size
    end

    # A compact hash, handy for assertions and JSON.
    def to_h
      {
        title: title,
        writes: writes,
        jobs: jobs,
        mails: mails,
        http: http,
        broadcasts: broadcasts,
        cache: cache,
        rolled_back: rolled_back.map(&:label),
        escaped_rollback: escaped_rollback.map(&:label),
        reads: reads.size,
        n_plus_ones: n_plus_ones.map { |(shape, table, n)| { table: table, count: n, sql: shape } },
        callbacks: callbacks.values.map { |c| { model: c.model, kind: c.kind, runs: c.runs, declared: c.declared } },
        duration_ms: duration_ms.round(1)
      }
    end

    def to_s
      Printer.new(self).to_s
    end

    # One line for logs: "2 writes (orders, line_items), 1 job, 1 mail · 14 reads · 12.3 ms"
    def summary
      parts = []
      w = writes
      parts << "#{w.values.sum} row#{'s' unless w.values.sum == 1} written (#{w.keys.join(', ')})" if w.any?
      { job: "job", mail: "mail", http: "HTTP call", broadcast: "broadcast", cache: "cache change" }.each do |kind, noun|
        n = count(kind)
        parts << "#{n} #{noun}#{'s' unless n == 1}" if n.positive?
      end
      parts << "#{rolled_back.size} rolled back" if rolled_back.any?
      parts << "no side effects" if parts.empty?
      "#{parts.join(', ')} · #{reads.size} reads · #{format('%.1f', duration_ms)} ms"
    end

    def inspect
      "#<Sidefx::Receipt #{committed.size} effects, #{reads.size} reads#{", #{rolled_back.size} rolled back" if rolled_back.any?}>"
    end
  end
end
