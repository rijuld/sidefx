# frozen_string_literal: true

module Sidefx
  # Compares a receipt with what a test expects. Shared by the Minitest
  # assertions and the RSpec matcher.
  #
  # Each key you pass is checked exactly; keys you leave out are not checked.
  #   writes:     { "orders" => 1 } (rows per table; unlisted tables must be 0) or Integer (total rows)
  #   jobs:       ["FulfillmentJob"] or Integer
  #   mails:      ["OrderMailer#receipt"] or Integer
  #   http:       ["POST api.stripe.com/v1/charges"] or Integer
  #   broadcasts: [...] or Integer
  #   cache:      [...] or Integer
  # Array entries may be Strings (exact) or Regexps.
  module Expectation
    KEYS = %i[writes jobs mails http broadcasts cache].freeze

    def self.check(receipt, expected)
      unknown = expected.keys.map(&:to_sym) - KEYS
      raise ArgumentError, "unknown side-effect keys: #{unknown.join(', ')} (use #{KEYS.join(', ')})" if unknown.any?

      expected.each_with_object([]) do |(key, want), problems|
        key = key.to_sym
        got = receipt.public_send(key)
        problem =
          if key == :writes
            check_writes(got, want)
          else
            check_list(got, want)
          end
        problems << "#{key}: #{problem}" if problem
      end
    end

    def self.check_writes(got, want)
      if want.is_a?(Integer)
        total = got.values.sum
        return total == want ? nil : "expected #{want} rows written in total, got #{total} #{got.inspect}"
      end

      want = want.to_h { |k, v| [k.to_s, v] }
      diff = (want.keys | got.keys).filter_map do |table|
        w = want.fetch(table, 0)
        g = got.fetch(table, 0)
        "#{table} expected #{w}, got #{g}" unless w == g
      end
      diff.empty? ? nil : diff.join("; ")
    end

    def self.check_list(got, want)
      if want.is_a?(Integer)
        return got.size == want ? nil : "expected #{want}, got #{got.size} #{got.inspect}"
      end

      remaining = got.dup
      missing = Array(want).reject do |w|
        i = remaining.index { |g| w.is_a?(Regexp) ? g.match?(w) : g == w.to_s }
        i && remaining.delete_at(i)
      end
      return nil if missing.empty? && remaining.empty?

      msg = []
      msg << "missing #{missing.map(&:inspect).join(', ')}" if missing.any?
      msg << "unexpected #{remaining.map(&:inspect).join(', ')}" if remaining.any?
      msg.join("; ")
    end

    def self.message(problems, receipt)
      "Side effects didn't match:\n  #{problems.join("\n  ")}\n\n#{receipt}"
    end
  end
end
