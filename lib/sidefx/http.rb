# frozen_string_literal: true

require "net/http"

module Sidefx
  # Records outgoing HTTP made through Net::HTTP, which covers Faraday's
  # default adapter, HTTParty, RestClient, ActiveResource and most SDKs.
  # Clients built on libcurl (Typhoeus, curb) or sockets are not seen.
  module HTTP
    def request(req, body = nil, &block)
      return super unless Recorder.active? && !Thread.current[:sidefx_in_http]

      begin
        Thread.current[:sidefx_in_http] = true
        response = super
      ensure
        Thread.current[:sidefx_in_http] = false
      end
      host = port == (use_ssl? ? 443 : 80) ? address : "#{address}:#{port}"
      path = req.path.to_s.split("?").first
      Recorder.effect(:http, "#{req.method} #{host}#{path}", detail: { status: response&.code })
      response
    end
  end
end

Net::HTTP.prepend(Sidefx::HTTP)
