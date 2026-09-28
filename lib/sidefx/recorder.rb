# frozen_string_literal: true

require "active_support/notifications"

module Sidefx
  # Listens to Rails instrumentation and files every event under the receipts
  # being recorded *on the current thread*. Other threads (parallel tests,
  # Puma workers) never leak into your receipt.
  module Recorder
    EVENTS = %w[
      sql.active_record
      start_transaction.active_record
      transaction.active_record
      enqueue.active_job
      enqueue_at.active_job
      enqueue_all.active_job
      process.action_mailer
      deliver.action_mailer
      broadcast.action_cable
      cache_write.active_support
      cache_write_multi.active_support
      cache_delete.active_support
      cache_delete_multi.active_support
      cache_increment.active_support
      cache_decrement.active_support
    ].freeze

    # Tables that belong to the job backend: their inserts *are* the job
    # enqueue, which we already report as a job.
    QUEUE_TABLES = /\A(solid_queue_|solid_cable_|solid_cache_|good_job|que_jobs|delayed_jobs)/
    INTERNAL_TABLES = %w[schema_migrations ar_internal_metadata sqlite_master sqlite_schema].freeze
    MAIL_JOBS = %w[ActionMailer::MailDeliveryJob ActionMailer::DeliveryJob ActionMailer::Parameterized::DeliveryJob].freeze

    class << self
      def install!
        return if @installed

        @installed = true
        EVENTS.each do |name|
          ActiveSupport::Notifications.subscribe(name) { |event| dispatch(event) }
        end
        require "sidefx/http"
        require "sidefx/callbacks"
      end

      def stack
        Thread.current[:sidefx_receipts] ||= []
      end

      # Open transactions seen while recording, innermost last. Each frame
      # collects the effects made inside it so a rollback can mark them.
      def frames
        Thread.current[:sidefx_frames] ||= []
      end

      def active?
        !stack.empty?
      end

      def record(receipt)
        install!
        stack.push(receipt)
        depth = frames.size
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        receipt.duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 if started
        frames.slice!(depth..) if depth
        stack.pop
      end

      # Add an effect to every receipt being recorded on this thread.
      def effect(kind, label, count: 1, detail: {})
        return unless active?

        e = Effect.new(kind: kind, label: label, detail: detail, count: count, location: Sidefx.app_location)
        stack.each { |r| r.effects << e }
        frames.last&.push(e)
        e
      end

      def callback(record, kind)
        return unless active?

        klass = record.class
        key = [klass.name, kind]
        stack.each do |r|
          run = (r.callbacks[key] ||= CallbackRun.new(model: klass.name, kind: kind, runs: 0, declared: Sidefx::Callbacks.declared(klass, kind)))
          run.runs += 1
        end
      end

      private

      def dispatch(event)
        return unless active?

        case event.name
        when "sql.active_record" then sql(event.payload)
        when "start_transaction.active_record" then frames.push([])
        when "transaction.active_record" then transaction(event.payload)
        when "enqueue.active_job", "enqueue_at.active_job" then job(event.payload[:job], event.payload)
        when "enqueue_all.active_job" then Array(event.payload[:jobs]).each { |j| job(j, {}) }
        when "process.action_mailer" then Thread.current[:sidefx_mail_action] = [event.payload[:mailer], event.payload[:action]]
        when "deliver.action_mailer" then mail(event.payload)
        when "broadcast.action_cable" then effect(:broadcast, event.payload[:broadcasting].to_s)
        else cache(event)
        end
      rescue StandardError => e
        # Never break the app because of a receipt.
        warn "[sidefx] ignored #{event.name}: #{e.class}: #{e.message}" if ENV["SIDEFX_DEBUG"]
      end

      def sql(payload)
        return if payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])

        op, table = SQL.classify(payload[:sql].to_s)
        return if op.nil? || INTERNAL_TABLES.include?(table) || table.match?(QUEUE_TABLES)

        if op == :select
          read = Read.new(table: table, shape: SQL.shape(payload[:sql].to_s), location: Sidefx.app_location)
          stack.each { |r| r.reads << read }
        else
          rows = payload[:affected_rows].to_i
          rows = 1 if rows.zero? && op == :insert
          effect(:write, "#{op.to_s.upcase} #{table}", count: rows, detail: { table: table, op: op, name: payload[:name] })
        end
      end

      def transaction(payload)
        frame = frames.pop
        return unless frame

        if payload[:outcome] == :commit
          frames.last&.concat(frame)
        else
          # :rollback, :restart and :incomplete all mean the *database* changes
          # didn't stick. Everything else (HTTP, mail, cache, jobs on another
          # backend) already left the process: flag it, don't hide it.
          frame.each do |e|
            if e.kind == :write
              e.rolled_back = true
            else
              e.detail[:inside_rollback] = true
            end
          end
        end
      end

      def job(job, payload)
        return if job.nil? || payload[:aborted]
        return if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued? == false

        name = job.class.name
        if MAIL_JOBS.include?(name)
          mailer, action = job.arguments.first(2)
          effect(:mail, "#{mailer}##{action}", detail: { via: :deliver_later, queue: job.queue_name })
        else
          when_ = job.scheduled_at ? " at #{Time.at(job.scheduled_at.to_f).utc.strftime('%H:%M:%S')}Z" : ""
          effect(:job, name, detail: { queue: job.queue_name, when: when_.strip })
        end
      end

      def mail(payload)
        return if payload[:perform_deliveries] == false

        to = Array(payload[:to]).join(", ")
        mailer, action = Thread.current[:sidefx_mail_action]
        label = mailer == payload[:mailer] && action ? "#{mailer}##{action}" : payload[:mailer].to_s
        effect(:mail, label, detail: { via: :deliver_now, to: to, subject: payload[:subject] })
      end

      def cache(event)
        op = event.name[/cache_(\w+?)(_multi)?\./, 1]
        keys = event.payload[:key]
        keys = keys.keys if keys.is_a?(Hash)
        Array(keys).each { |k| effect(:cache, "#{op} #{k}", detail: { op: op.to_sym }) }
      end
    end
  end
end
