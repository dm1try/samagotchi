# frozen_string_literal: true

require_relative "../session"
require_relative "../reply_wait"
require_relative "../parent_report"
require_relative "exit"
require_relative "../session_access"

module Samagotchi
  module CLI
    # The parent-agent side shared by `chi send --wait` and `chi answer`:
    # --format json's one object whatever the end, the session id resolved
    # for it, and the wait for what comes next, reported the ParentReport
    # way (Ctrl-C included). The including class (a CLI::Command) defines
    # #parse (options, or an exit status) and #run_parsed(options), sets
    # @stdout, @stderr and @access (a SessionAccess backend), and may
    # override the constants (specs stub them on the class).
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
        status = begin
          run_parsed(options)
        rescue SessionAccess::RemoteFailed => e
          # A remote that went away mid-run: the command's line, and with
          # --format json its object.
          error_line("#{command_name}: #{e.message}")
          Exit::FAILED
        end
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
        @session_id = @access.resolve(given)
      rescue ArgumentError => e
        error_line("#{command_name}: #{e.message}")
        nil
      end

      # Wait for what +target+ binds (ReplyWait) and report it. Ctrl-C
      # leaves the turn running (130).
      # @param target [ReplyWait::Target] which turn, from the cursor and
      #   baseline prepare_wait read; its report_turn_id is the turn id the
      #   report names, even when ReplyWait takes the next reply
      # @return [Integer] the exit status
      def wait_for_reply(id, target:, timeout:)
        report_turn_id = target.report_turn_id
        result = @access.wait_reply(id, **target.to_h, timeout: timeout, poll_interval: self.class::POLL_INTERVAL)
        result.turn_id = report_turn_id if report_turn_id && !report_turn_id.to_s.empty?
        result.text = result.text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        @reported = true
        # What a parent may pick there: config.yml tightened by the session's
        # own. Machine-local (this machine's config.yml): remotely the
        # server's (P2's wait route).
        strategy = @access.parent_strategy(id)
        ParentReport.report(result, session_id: id, stdout: @stdout, stderr: @stderr, command: command_name,
                                    json: @json, timeout: timeout, extra: report_extra, strategy: strategy,
                                    via: @access.invocation)
      rescue Interrupt
        if @json
          @stdout.puts(ParentReport.json_line(ReplyWait::Result.new(status: :canceled, turn_id: report_turn_id), session_id: id,
                                                                                        extra: report_extra))
          @stdout.flush
          @reported = true
        end
        error_line("#{command_name}: still running: #{ParentReport.still_running_hint(id, report_turn_id, via: @access.invocation)}")
        Exit::INTERRUPTED
      rescue ArgumentError
        error_line("#{command_name}: the session is gone (deleted while waiting)")
        Exit::FAILED
      end

      # More keys for the JSON object: answered_here: false when chi
      # answer's answer didn't go in (the question was no longer open).
      def report_extra
        @answered_here == false ? { answered_here: false } : {}
      end
    end
  end
end
