# frozen_string_literal: true

require "rails/railtie"

module Sidefx
  # In development, warns in the log when a GET request writes to the
  # database, enqueues jobs, sends mail or broadcasts. Configure with:
  #
  #   config.sidefx.requests = :log   # summary line for every request
  #   config.sidefx.requests = false  # off
  class Railtie < Rails::Railtie
    config.sidefx = ActiveSupport::OrderedOptions.new
    config.sidefx.requests = nil

    initializer "sidefx.middleware" do |app|
      mode = app.config.sidefx.requests
      mode = :warn if mode.nil? && Rails.env.development?
      if mode
        require "sidefx/middleware"
        app.middleware.use Sidefx::Middleware, mode: mode
      end
    end
  end
end
