# frozen_string_literal: true

require "sidefx"
require "sidefx/expectation"

module Sidefx
  # require "sidefx/rspec" in spec_helper.rb.
  #
  #   expect { checkout.call }.to have_side_effects(writes: { orders: 1 }, jobs: ["FulfillmentJob"])
  #   expect { get "/dashboard" }.not_to have_side_effects
  module RSpecMatchers
    class HaveSideEffects
      def initialize(expected)
        @expected = expected
      end

      def supports_block_expectations?
        true
      end

      def matches?(block)
        @receipt = Sidefx.receipt(&block)
        if @expected.empty?
          !@receipt.pure?
        else
          @problems = Expectation.check(@receipt, @expected)
          @problems.empty?
        end
      end

      def does_not_match?(block)
        raise ArgumentError, "use `to have_side_effects(...)` with expectations, or `not_to have_side_effects` with none" if @expected.any?

        @receipt = Sidefx.receipt(&block)
        @receipt.pure?
      end

      def failure_message
        return "expected the block to have side effects, but it had none\n\n#{@receipt}" if @expected.empty?

        Expectation.message(@problems, @receipt)
      end

      def failure_message_when_negated
        "expected no side effects, but the block had #{@receipt.committed.size}:\n\n#{@receipt}"
      end

      def description
        @expected.empty? ? "have side effects" : "have side effects #{@expected.inspect}"
      end
    end

    def have_side_effects(expected = {}) # rubocop:disable Naming/PredicateName
      HaveSideEffects.new(expected)
    end
  end
end

RSpec.configure { |c| c.include Sidefx::RSpecMatchers } if defined?(RSpec) && RSpec.respond_to?(:configure)
