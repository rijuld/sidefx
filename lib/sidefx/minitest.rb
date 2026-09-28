# frozen_string_literal: true

require "sidefx"
require "sidefx/expectation"

module Sidefx
  # require "sidefx/minitest" in test_helper.rb.
  #
  #   assert_side_effects(writes: { orders: 1 }, jobs: ["FulfillmentJob"], http: 0) do
  #     Checkout.new(cart).call
  #   end
  #
  #   assert_no_side_effects { get dashboard_path }
  #
  # On failure the message is the full receipt, so you see what *did* happen.
  module Assertions
    def assert_side_effects(expected = {}, &block)
      receipt = Sidefx.receipt(&block)
      problems = Expectation.check(receipt, expected)
      assert problems.empty?, -> { Expectation.message(problems, receipt) }
      receipt
    end

    def assert_no_side_effects(&block)
      receipt = Sidefx.receipt(&block)
      assert receipt.pure?, -> { "Expected no side effects, but the block had #{receipt.committed.size}:\n\n#{receipt}" }
      receipt
    end
  end
end

# ActiveSupport::TestCase (and so every Rails test) inherits from Minitest::Test.
Minitest::Test.include(Sidefx::Assertions) if defined?(Minitest::Test)
