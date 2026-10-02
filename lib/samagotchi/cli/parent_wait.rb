# frozen_string_literal: true

require_relative "../session"
require_relative "../reply_wait"
require_relative "../parent_report"
require_relative "exit"

module Samagotchi
  module CLI
    # The parent-agent side shared by `chi send --wait` and `chi answer`:
    # --format json's one object whatever the end, the session id resolved
    # for it, and the wait for what comes next, reported the ParentReport
    # way (Ctrl-C included). The including class (a CLI::Command) defines
    # #parse (options, or an exit status) and #run_parsed(options), sets
    # @stdout, @stderr and @state_dir, and may override the constants
    # (specs stub them on the class).
    module ParentWait
      POLL_INTERVAL = ReplyWait::POLL_INTERVAL
      # No live worker this long while waiting: it died before it could mark
      # the session (a worker takes well under a second to start).
      WORKER_GONE_AFTER = 5
      FORMATS = %w[text json].freeze

      # @return [Integer] the exit status
      def run
        options = parse
        return options if options.is_a?(Integer)

        @json = options[:format] == "json"
        # With --format json stdout is one JSON object, whatever the end: a
        # failure before the wait is reported from stderr's last line.
        @stderr = ParentReport::LastLine.new(@stderr) if @json
        status = run_parsed(options)
        if @json && !@reported && status == 1
          detail = @stderr.last.to_s.delete_prefix("#{command_name}: ")
          @stdout.puts(ParentReport.error_line(detail, session_id: @session_id))
          @stdout.flush
        end
        status
      end

      private

      # The full id of +given+ (an id or a prefix), kept for the JSON
      # error line; nil after the error line.
      # @return [String, nil]
      def resolve(given)
        id = Session.resolve_id(given, state_dir: @state_dir)
        Session.load(id, state_dir: @state_dir)
        @session_id = id
      rescue ArgumentError => e
        error_line("#{command_name}: #{e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"}")
        nil
      end

      # Wait for the session's next reply past +cursor+ (ReplyWait) and
      # report it. Ctrl-C leaves the turn running (130).
      # @param owner_grace [Numeric, nil] seconds with no live worker before
      #   it counts as gone; nil waits for whatever wakes one
      # @return [Integer] the exit status
      def wait_for_reply(id, cursor:, baseline:, timeout:, owner_grace: self.class::WORKER_GONE_AFTER)
        result = ReplyWait.call(id, state_dir: @state_dir, cursor: cursor, timeout: timeout, baseline: baseline,
                                    owner_grace: owner_grace, poll_interval: self.class::POLL_INTERVAL)
        result.text = result.text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        @reported = true
        ParentReport.report(result, session_id: id, stdout: @stdout, stderr: @stderr, command: command_name,
                                    json: @json, timeout: timeout)
      rescue Interrupt
        if @json
          @stdout.puts(ParentReport.json_line(ReplyWait::Result.new(status: :canceled), session_id: id))
          @stdout.flush
          @reported = true
        end
        error_line("#{command_name}: still running: chi --attach #{id}")
        Exit::INTERRUPTED
      rescue ArgumentError
        error_line("#{command_name}: the session is gone (deleted while waiting)")
        Exit::FAILED
      end
    end
  end
end
