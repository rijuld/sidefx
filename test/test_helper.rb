# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "logger"
require "active_record"
require "active_job"
require "action_mailer"
require "action_cable"
require "action_cable/subscription_adapter/test"
require "global_id"
require "minitest/autorun"
require "sidefx"
require "sidefx/minitest"

Sidefx.app_root = File.expand_path("..", __dir__)

ActiveRecord::Base.logger = nil
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
GlobalID.app = "sidefx-test"
ActiveRecord::Base.include(GlobalID::Identification)
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.logger = Logger.new(nil)
ActionCable.server.config.cable = { "adapter" => "test" }
ActionCable.server.config.logger = Logger.new(nil)

ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
    t.string :email
    t.integer :orders_count, default: 0
    t.timestamps
  end
  create_table :orders do |t|
    t.references :user
    t.integer :total, default: 0
    t.string :status, default: "new"
    t.timestamps
  end
  create_table :line_items do |t|
    t.references :order
    t.string :sku
    t.integer :qty
  end
  create_table :audit_logs do |t|
    t.string :message
  end
end

class FulfillmentJob < ActiveJob::Base
  def perform(order_id); end
end

class OrderMailer < ActionMailer::Base
  default from: "shop@example.com"

  def receipt(order)
    mail(to: order.user.email, subject: "Your order ##{order.id}", body: "Thanks!")
  end
end

class User < ActiveRecord::Base
  has_many :orders
end

class LineItem < ActiveRecord::Base
  belongs_to :order
end

class AuditLog < ActiveRecord::Base; end

class Order < ActiveRecord::Base
  belongs_to :user, counter_cache: true
  has_many :line_items

  before_save :compute_total
  after_create_commit :fulfill, if: :persisted?

  def compute_total
    self.total = line_items.sum { |li| li.qty.to_i * 10 }
  end

  def fulfill
    FulfillmentJob.perform_later(id)
  end
end

module SidefxTestHelpers
  def setup
    [LineItem, Order, AuditLog, User].each(&:delete_all)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActionMailer::Base.deliveries.clear
    @user = User.create!(name: "Ada", email: "ada@example.com")
  end
end
