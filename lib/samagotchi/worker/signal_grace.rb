# frozen_string_literal: true

require_relative "../log"
require_relative "../session"

module Samagotchi
  class Worker
    # A signal's grace, on a thread of its own (WorkerSignals#fire):
    # #signalled?, #signal_leave, #signalled, #signal_hard_exit and
    # #signal_grace_expired, with the SIGNAL_* times. Writes @grace_expired
    # (under @signal_mutex). Worker writes the rest it reads: @run_thread
    # (#run), @loop_started (#run_loop), @left_loop (#run's ensure),
    # @turn_ending (the turn observer) and the grace ivars and @signal_mutex
    # (#initialize). Reads those, @signals, @engine, @waker, @session_id and
    # @state_dir.
    module SignalGracePart
      # How long a signalled worker's turn has to end (it is canceled at once,
      # and again every SIGNAL_RETRY until it ends: a signal that lands just
      # before the turn begins finds none to cancel).
      SIGNAL_GRACE = 3.0
      # A second signal, or a TERM after `chi sessions stop` marked the
      # session stopped (that stop already canceled over the Bridge and waits
      # only seconds for the lock): this much.
      SIGNAL_SHORT_GRACE = 0.5
      SIGNAL_RETRY = 0.1
      # After the grace ran out and the signal was raised: the process ends
      # this much later at the latest (a teardown that hangs).
      SIGNAL_HARD_EXIT = 10.0

      private

      def signalled? = !@signals.signal.nil?

      # @return [Symbol] :stopped when the session was stopped too (chi
      #   sessions stop TERMs its worker), else :signal
      def signal_leave
        Session.stopped_marker?(@session_id, state_dir: @state_dir) ? :stopped : :signal
      end

      # A signal (WorkerSignals#fire), on a thread of its own: the loop wakes
      # (an idle worker leaves at once), the running turn is canceled as a
      # Stop (again every SIGNAL_RETRY, until the loop has left), and when
      # the grace runs out first, #signal_grace_expired. A turn that has
      # ended and runs its after_turn hooks (which store the answer's display
      # and refs) is no longer canceled, and gets until SIGNAL_HARD_EXIT
      # past the grace, the worker's own end of the turn (its saves, after
      # the turn stopped running) too: the loop leaves next. A grace that runs out before the loop started waits
      # for it (the loop's first look leaves). A signal after the loop left
      # (the teardown, the caller's last steps) only brings the hard exit.
      def signalled(name, count)
        Log.info(:worker, "signal", signal: name, count: count, turn_running: @engine&.turn_running? || false)
        return signal_hard_exit if @left_loop

        @waker.wake
        short = count > 1 || Session.stopped_marker?(@session_id, state_dir: @state_dir)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deadline = now + (short ? @signal_short_grace : @signal_grace)
        hooks_deadline = deadline + @signal_hard_exit
        ended = false
        until @left_loop
          running = @engine&.turn_running?
          ended ||= running && @turn_ending
          @engine.cancel_current_turn!(:signal) if running && !ended
          break if @loop_started && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (ended ? hooks_deadline : deadline)

          sleep(SIGNAL_RETRY)
        end
        signal_grace_expired(name) unless @left_loop
      rescue StandardError => e
        Log.warn(:worker, "signal_failed", signal: name, error: e.class.name, msg: e.message)
      end

      # The process ends SIGNAL_HARD_EXIT from now at the latest.
      def signal_hard_exit
        sleep(@signal_hard_exit)
        @signals.hard_exit
      end

      # The turn didn't end in time (a tool that ignores the cancel, slow
      # after_turn hooks): the session is saved as it is now (a turn that has
      # ended: with it), and the signal raised in the loop's thread, so
      # Worker#run's teardown and the lock's release still run. The process
      # ends SIGNAL_HARD_EXIT later at the latest. Once, whatever the signals.
      def signal_grace_expired(name)
        expired = @signal_mutex.synchronize { !@grace_expired && !@left_loop && (@grace_expired = true) }
        return unless expired

        Log.warn(:worker, "signal_grace_expired", signal: name, turn_running: @engine&.turn_running? || false)
        save_or_log(:signal) { save_session }
        # Not once the loop has left (it may have, during the save).
        @signal_mutex.synchronize { @run_thread&.raise(SignalException.new(name)) unless @left_loop }
        signal_hard_exit
      end
    end
  end
end
