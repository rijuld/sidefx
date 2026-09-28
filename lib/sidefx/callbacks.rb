# frozen_string_literal: true

require "active_record"

module Sidefx
  # Notes which ActiveRecord callback chains ran, and lists the callbacks your
  # code declared on them (framework-internal ones are counted, not listed).
  module Callbacks
    KINDS = %i[validation save create update destroy commit rollback touch].freeze

    def run_callbacks(kind, type = nil, &block)
      Recorder.callback(self, kind) if KINDS.include?(kind) && Recorder.active?
      super
    end

    # One callback your code declared, e.g. "before_save :compute_total".
    Declared = Struct.new(:label, :location, :conditional, keyword_init: true)

    # [Declared, ...] for callbacks defined outside gems.
    def self.declared(klass, kind)
      chain = klass.__callbacks[kind]
      return [] unless chain

      chain.filter_map do |cb|
        filter = cb.filter
        location =
          case filter
          when Symbol then klass.instance_method(filter).source_location rescue nil # rubocop:disable Style/RescueModifier
          when Proc then filter.source_location
          end
        next unless location && Sidefx.app_path?(location.first)

        name = filter.is_a?(Symbol) ? ":#{filter}" : "{ … }"
        conditional = Array(cb.instance_variable_get(:@if)).any? || Array(cb.instance_variable_get(:@unless)).any?
        timing = %i[commit rollback].include?(kind) ? "after" : cb.kind.to_s
        Declared.new(label: "#{timing}_#{kind} #{name}", location: Sidefx.short_path("#{File.expand_path(location.first)}:#{location.last}"), conditional: conditional)
      end
    end
  end
end

ActiveRecord::Base.prepend(Sidefx::Callbacks)
