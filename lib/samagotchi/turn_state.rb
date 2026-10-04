# frozen_string_literal: true

require "monitor"

module Samagotchi
  # A session's turn as other threads see it: whether one runs, its cancel
  # controller and event sink, the plugin steers waiting for its next
  # boundary, and the activity clock the idle jobs read.
  #
  # The turn thread writes it (Engine#begin_turn, #release_turn); the idle
  # scheduler, the bridge's request threads, plugin threads and the UIs
  # read it. The lock is a leaf: nothing is called out while it is held,
  # so any lock may be held around a call into it, and it is never held
  # around anything else.
  class TurnState
    # @param clock [#call] monotonic seconds
    def initialize(clock:)
      @clock = clock
      @lock = Monitor.new
      @last_activity_at = clock.call
      @activity_seq = 0
      @running = false
      @controller = nil
      @sink = nil
      @steers = []
      @carried_steers = []
    end

    # ── Activity clock ──────────────────────────────────────────────────

    # Activity happened (user input, a finished turn): the clock moves to
    # +now+ and the sequence advances, so the idle jobs re-arm.
    # @param now [Float, nil] monotonic seconds; the clock's now by default
    def record_activity(now = nil)
      now = now ? now.to_f : @clock.call
      @lock.synchronize do
        @last_activity_at = now
        @activity_seq += 1
      end
    end

    # Start the idle window now without counting it as activity (the
    # sequence stays): the Engine does once its plugins have loaded, so a
    # slow plugin start doesn't shorten the first window.
    def restart_clock!
      now = @clock.call
      @lock.synchronize { @last_activity_at = now }
    end

    # @return [Float] monotonic seconds of the last activity
    def last_activity_at
      @lock.synchronize { @last_activity_at }
    end

    # @return [Integer] how many times activity was recorded
    def activity_seq
      @lock.synchronize { @activity_seq }
    end

    # ── The turn ────────────────────────────────────────────────────────

    # @return [Boolean] whether a turn runs
    def running?
      @lock.synchronize { @running }
    end

    # A turn begins: running, with its controller and sink, in one step.
    def begin!(controller:, sink:)
      @lock.synchronize do
        @running = true
        @controller = controller
        @sink = sink
        @steers.concat(@carried_steers)
        @carried_steers = []
      end
    end

    # The turn is over: not running, no controller, sink or steers.
    # @return [Array<Hash>] the steers it never took ({text:, source:})
    def finish!
      @lock.synchronize do
        @running = false
        @controller = nil
        @sink = nil
        @steers.tap { @steers = [] }
      end
    end

    # @return [CancellationController, nil] the running turn's controller
    def controller
      @lock.synchronize { @controller }
    end

    # Cancel the running turn, if any (outside the lock).
    # @return [Boolean] whether a cancellation was triggered
    def cancel!(reason)
      ctrl = controller
      return false unless ctrl

      ctrl.cancel!(reason)
    end

    # @return [Array(Boolean, #call)] whether a turn runs, and its sink
    def in_turn_sink
      @lock.synchronize { [@running, @sink] }
    end

    # ── Steers ──────────────────────────────────────────────────────────

    # Queue +text+ for the running turn's next boundary.
    # @return [Boolean] whether it was queued (false: blank, or no turn)
    def steer(text, source:)
      text = text.to_s.strip
      return false if text.empty?

      @lock.synchronize do
        return false unless @running

        @steers << { text: text, source: source.to_s }
      end
      true
    end

    # Queue +text+ for the next turn that begins: it is a steer of that turn
    # from its first boundary on (a continue turn's answer text, which has
    # no turn running yet to steer). Taken by #begin!.
    # @return [Boolean] whether it was queued (false: blank)
    def steer_next_turn(text, source:)
      text = text.to_s.strip
      return false if text.empty?

      @lock.synchronize { @carried_steers << { text: text, source: source.to_s } }
      true
    end

    # @return [Boolean] whether #steer_next_turn queued anything a turn has
    #   yet to begin with
    def carried_steers?
      @lock.synchronize { !@carried_steers.empty? }
    end

    # Drop what #steer_next_turn queued and no turn began with (a no-op
    # once #begin! took it).
    # @return [Array<Hash>] the steers dropped ({text:, source:})
    def drop_carried_steers
      @lock.synchronize { @carried_steers.tap { @carried_steers = [] } }
    end

    # @return [Array<Hash>] the steers queued so far ({text:, source:}), taken
    def take_steers
      @lock.synchronize { @steers.tap { @steers = [] } }
    end
  end
end
