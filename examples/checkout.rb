# frozen_string_literal: true

# A realistic checkout, and the receipt for it.
#
#   bundle exec ruby examples/checkout.rb
#
# Everything runs locally: an in-memory SQLite database and a fake payment
# gateway on 127.0.0.1.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "logger"
require "socket"
require "active_record"
require "active_job"
require "action_mailer"
require "action_cable"
require "action_cable/subscription_adapter/test"
require "global_id"
require "sidefx"

Sidefx.app_root = File.expand_path("..", __dir__)
ActiveRecord::Base.logger = nil
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
GlobalID.app = "shop"
ActiveRecord::Base.include(GlobalID::Identification)
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.logger = Logger.new(nil)
ActionCable.server.config.cable = { "adapter" => "test" }
ActionCable.server.config.logger = Logger.new(nil)
CACHE = ActiveSupport::Cache::MemoryStore.new

ActiveRecord::Schema.define do
  create_table(:customers) { |t| t.string :email; t.integer :orders_count, default: 0 }
  create_table(:products) { |t| t.string :sku; t.string :name; t.integer :stock; t.integer :price }
  create_table(:orders) { |t| t.references :customer; t.integer :total, default: 0; t.string :state }
  create_table(:line_items) { |t| t.references :order; t.references :product; t.integer :qty }
  create_table(:audit_logs) { |t| t.string :message }
end

class Customer < ActiveRecord::Base
  has_many :orders
end

class Product < ActiveRecord::Base; end

class LineItem < ActiveRecord::Base
  belongs_to :order
  belongs_to :product
end

class AuditLog < ActiveRecord::Base; end

class Order < ActiveRecord::Base
  belongs_to :customer, counter_cache: true
  has_many :line_items

  before_save :compute_total
  after_create_commit :schedule_fulfillment

  def compute_total
    self.total = line_items.sum { |li| li.qty * li.product.price }
  end

  def schedule_fulfillment
    FulfillmentJob.set(wait: 10.minutes).perform_later(self)
  end
end

class FulfillmentJob < ActiveJob::Base
  def perform(order); end
end

class OrderMailer < ActionMailer::Base
  default from: "shop@example.com"

  def confirmation(order)
    mail(to: order.customer.email, subject: "Order ##{order.id} confirmed", body: "Thanks!")
  end
end

# A pretend payment gateway listening on localhost.
GATEWAY = TCPServer.new("127.0.0.1", 0)
Thread.new do
  loop do
    client = GATEWAY.accept
    while (line = client.gets) && line != "\r\n"; end
    client.write("HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    client.close
  end
end

module Payments
  def self.charge(order)
    Net::HTTP.post(URI("http://127.0.0.1:#{GATEWAY.addr[1]}/v1/charges"), "amount=#{order.total}")
  end
end

class Checkout
  def initialize(customer, cart)
    @customer = customer
    @cart = cart
  end

  def call
    order = Order.transaction do
      order = @customer.orders.build(state: "paid")
      @cart.each do |sku, qty|
        product = Product.find_by!(sku: sku)
        order.line_items.build(product: product, qty: qty)
        product.decrement!(:stock, qty)
      end
      order.save!
      order
    end

    Payments.charge(order)
    record_audit(order)
    CACHE.delete("storefront/stock")
    ActionCable.server.broadcast("orders", { id: order.id })
    OrderMailer.confirmation(order).deliver_later
    order.line_items.map { |li| li.product.name } # for the confirmation page
  end

  private

  # Audit logging is "best effort": a savepoint that gets rolled back when
  # the audit service says no. Easy to miss when reading the code.
  def record_audit(order)
    AuditLog.transaction(requires_new: true) do
      AuditLog.create!(message: "order #{order.id} paid")
      raise ActiveRecord::Rollback unless ENV["AUDIT_ENABLED"]
    end
  end
end

customer = Customer.create!(email: "ada@example.com")
%w[mug tee cap sticker].each_with_index do |sku, i|
  Product.create!(sku: sku, name: sku.capitalize, stock: 10, price: (i + 1) * 500)
end
CACHE.write("storefront/stock", "warm")

Sidefx.print("Checkout#call") do
  Checkout.new(customer, { "mug" => 1, "tee" => 2, "cap" => 1, "sticker" => 3 }).call
end
