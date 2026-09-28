# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

require_relative "sidefx/version"
require_relative "sidefx/sql"
require_relative "sidefx/receipt"
require_relative "sidefx/printer"
require_relative "sidefx/recorder"

# Get a receipt for everything a block of Rails code did to the world:
# rows written, callbacks fired, jobs enqueued, mail sent, HTTP called,
# cache changed, broadcasts made, and what a rollback quietly undid.
#
#   receipt = Sidefx.receipt("checkout") { Checkout.new(cart).call }
#   puts receipt
#   receipt.writes   # => { "orders" => 1, "line_items" => 3 }
#   receipt.jobs     # => ["FulfillmentJob"]
module Sidefx
  class << self
    # Record the block and return the Receipt. The block's own return value is
    # available as receipt.value; exceptions propagate after recording.
    def receipt(title = nil, &block)
      r = Receipt.new(title)
      Recorder.record(r) { r.instance_variable_set(:@value, block.call) }
      r
    end

    # Record the block, print the receipt, and return the block's value.
    # Handy in `rails console`: Sidefx.print { user.destroy }
    def print(title = nil, io: $stdout, &block)
      r = Receipt.new(title)
      value = nil
      begin
        Recorder.record(r) { value = block.call }
      ensure
        io.puts r
      end
      value
    end

    # Directories whose frames count as "your code". Defaults to Rails.root
    # when Rails is loaded, else the current directory.
    attr_writer :app_root

    def app_root
      @app_root ||= (defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd)
    end

    GEM_PATHS = %r{/gems/|/rubygems/|/ruby/\d|/lib/ruby/|<internal:|/sidefx/lib/}

    def app_path?(path)
      path = path.to_s
      path = File.expand_path(path) unless path.start_with?("/", "<")
      path.start_with?(app_root) && !path.match?(GEM_PATHS) && !path.include?("/vendor/")
    end

    # First caller frame that belongs to the app, as "app/models/order.rb:12".
    def app_location
      loc = caller_locations(2)&.find { |l| app_path?(l.absolute_path || l.path) }
      loc && short_path("#{loc.absolute_path || loc.path}:#{loc.lineno}")
    end

    def short_path(path)
      path.to_s.delete_prefix("#{app_root}/")
    end
  end

  class Receipt
    # The block's return value.
    attr_reader :value
  end
end

require_relative "sidefx/railtie" if defined?(Rails::Railtie)
