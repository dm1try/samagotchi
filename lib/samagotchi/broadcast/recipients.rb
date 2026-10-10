# frozen_string_literal: true

require "time"
require_relative "../session"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Broadcast
    # A session a broadcast may concern.
    # @!attribute project [String, nil] its git project's root
    # @!attribute live [Boolean] a worker runs it now
    # @!attribute owner [String, nil] "worker", "tui" (a chi REPL, which
    #   takes no notes) or nil
    Recipient = Data.define(:id, :short_id, :project, :cwd, :desc, :live, :owner) do
      def repl? = owner == "tui"
    end

    # Who a broadcast goes to: the user's own sessions, not delegate
    # children (their parent relays what concerns them) and not scratch
    # ones, that a worker or a chi REPL runs now or that ended a turn in
    # the last +active_hours+. Forks count: they are the user's sessions.
    # Archived sessions don't; test runs only when chi runs as one.
    module Recipients
      module_function

      # @return [Array<Recipient>] newest first
      def list(state_dir:, active_hours:, include_tests: Session.test_session_env?, now: Time.now)
        cutoff = now - (active_hours.to_f * 3600)
        SessionManager.session_summaries(include_tests: include_tests, state_dir: state_dir).filter_map do |row|
          next if row[:delegate] || row[:scratch]
          next unless row[:live] || row[:owner] == "tui" || active_since?(row, cutoff, state_dir)

          Recipient.new(id: row[:id], short_id: row[:short_id], project: row[:project], cwd: row[:cwd],
                        desc: row[:desc], live: row[:live], owner: row[:owner])
        end
      end

      # The user's last turn there ended after +cutoff+. updated_at moves on
      # every save (a note absorbed, a resume), so it counts only for a
      # session with no turn recorded; it is never older than the last
      # turn's end, so an older one rules the session out unread.
      def active_since?(row, cutoff, state_dir)
        return false unless (time(row[:updated_at]) || Time.at(0)) >= cutoff

        session = Session.summary_from_file(Session.session_file(row[:id], state_dir: state_dir))
        ended = time(session&.last_turn&.ended_at)
        (ended || time(row[:updated_at])) >= cutoff
      end
      private_class_method :active_since?

      def time(value)
        value && Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
      private_class_method :time
    end
  end
end
