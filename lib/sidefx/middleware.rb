# frozen_string_literal: true

require "sidefx"

module Sidefx
  # Rack middleware that records a receipt per request.
  #
  #   mode: :warn  log only when a GET/HEAD request changes something (default)
  #   mode: :log   log a one-line summary for every request, full receipt on warnings
  #
  # Effects made while the response body streams are not captured.
  class Middleware
    SAFE = %w[GET HEAD OPTIONS].freeze
    UNSAFE_KINDS = %i[write job mail broadcast].freeze

    def initialize(app, mode: :warn, logger: nil)
      @app = app
      @mode = mode.to_sym
      @logger = logger
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      title = "#{method} #{env['PATH_INFO']}"
      response = nil
      receipt = Sidefx.receipt(title) { response = @app.call(env) }

      unsafe = SAFE.include?(method) && receipt.committed.any? { |e| UNSAFE_KINDS.include?(e.kind) }
      if unsafe
        logger.warn("[sidefx] #{title} is a safe method but changed things:\n#{receipt}")
      elsif @mode == :log
        logger.info("[sidefx] #{title} → #{receipt.summary}")
      end
      response
    end

    private

    def logger
      @logger ||= defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ? Rails.logger : Logger.new($stderr)
    end
  end
end
