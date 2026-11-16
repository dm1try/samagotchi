# frozen_string_literal: true

require_relative "../bridge_client"
require_relative "../client_id"
require_relative "../degrade"
require_relative "../log"
require_relative "../session_manager"

module Samagotchi
  class Worker
    # A `chi scratch` worker whose terminal is gone: #start_scratch_watch (a
    # thread that cancels an unattended turn each tick), #cancel_unattended_turn,
    # #scratch_unattended? and #leave_scratch (the idle pass's leave), with
    # SCRATCH_JOIN_GRACE and SCRATCH_GONE_AFTER. Writes @unattended_since
    # (the scratch thread and the loop, no lock: a monotonic stamp, benign).
    # Reads @poll_interval, @session, @bridge, @started_at (#start), @engine,
    # @session_id and @waker. #scratch? and @scratch_watch (#start_background,
    # #teardown) stay in Worker.
    module ScratchPart
      # How long a scratch worker waits for its terminal's first stream
      # (AttachLauncher attaches within BRIDGE_WAIT of the spawn).
      SCRATCH_JOIN_GRACE = 30

      # How long a scratch worker's terminal may have no stream open, after
      # it had one, before it counts as gone: twice the attached terminal's
      # whole reconnect ladder (TerminalUI::LocalLink#reconnect_delays), so
      # a reconnect gap (a dropped stream, a slow worker) never reads as a
      # terminal that left.
      SCRATCH_GONE_AFTER = 2 * BridgeClient::EventStream::REDISCOVER_DELAYS.sum

      private

      # A scratch session's turn never runs on with no terminal: a turn
      # waiting on a question or an approval would keep the worker up for
      # nobody. Each tick while a turn runs and its terminal is gone
      # (#scratch_unattended?), the question is dropped and the turn
      # cancelled as a stop cancels it; the idle pass then leaves
      # (:scratch_left) and the session is deleted.
      def start_scratch_watch
        Thread.new do
          loop do
            sleep(@poll_interval)
            Degrade.call(:worker, "scratch_watch_failed") { cancel_unattended_turn }
          end
        end.tap { |thread| thread.report_on_exception = false }
      end

      def cancel_unattended_turn
        return unless @engine.turn_running? && scratch_unattended?

        Log.info(:worker, "scratch_turn_cancelled", sid: @session_id)
        @engine.cancel_question(SessionManager::STOP_CANCEL_REASON) if @engine.pending_question
        @engine.cancel_current_turn!(SessionManager::STOP_CANCEL_REASON.to_sym)
        @waker.wake
      end

      # Whether this is a `chi scratch` session's worker whose terminal is
      # gone: no terminal stream (a tui: client id's) open for
      # SCRATCH_GONE_AFTER, after a stream was (a killed TUI's closes as its
      # writer reads the hang-up), or none came within SCRATCH_JOIN_GRACE.
      # Any other stream (a web tab's, which chi web refuses for a scratch
      # session anyway) never keeps it. Its terminal deletes it on every way
      # out it sees; this is for the ones it doesn't (kill -9, a closed
      # terminal window).
      def scratch_unattended?
        return false unless @session&.scratch && @bridge

        if @bridge.open_streams_of(ClientId::TUI_PREFIX).positive?
          @unattended_since = nil
          return false
        end
        return monotonic_now - @started_at >= SCRATCH_JOIN_GRACE unless @bridge.streams_served.positive?

        # Set by the first look (the scratch watch or the idle pass) that
        # finds no stream; a stream back resets it above.
        @unattended_since ||= monotonic_now
        monotonic_now - @unattended_since >= SCRATCH_GONE_AFTER
      end

      # #leave_idle for a scratch worker its terminal left: checked again with
      # the event log held, then the intake closes. The session is deleted
      # once the lock is free (WorkerBoot.run_session_loop: :scratch_left).
      # @return [Boolean] false when a client came back since
      def leave_scratch
        stop_bridge_after do
          @engine.synchronize_events do
            # A turn still running is the scratch watch's to cancel first.
            next false unless scratch_unattended? && !@engine.turn_running?

            @bridge&.close_intake
            @engine.stop_idle(join: false)
            Log.info(:worker, "scratch_left", served: @bridge.streams_served)
            true
          end
        end
      end
    end
  end
end
