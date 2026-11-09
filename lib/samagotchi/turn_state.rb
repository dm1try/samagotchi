# frozen_string_literal: true

require "monitor"

module Samagotchi
  # A session's turn as other threads see it: whether one runs, its cancel
  # controller and event sink, the plugin steers waiting for its next
  # boundary, whether a person's message waits for it (its caller's
  # input_waiting: probe), the turn's TurnContext (#context, and the last
  # turn's, #last_context), and the activity clock the idle jobs read.
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
      @thread = nil
      @ended = false
      @input_waiting = nil
      @input_waiting_warned = false
      @context = nil
      @last_context = nil
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

    # A turn begins, on the calling thread (the turn's own): running, with
    # its context, controller, sink and input_waiting probe, in one step, so
    # no reader sees a running turn with the previous turn's context.
    # @param context [TurnContext, nil] the turn's, built before (nil: none,
    #   a spec's bare turn)
    # @param input_waiting [#call, nil] true while a person's message waits
    #   for the turn's next boundary (Engine#input_waiting?); nil: never
    def begin!(controller:, sink:, context: nil, input_waiting: nil)
      @lock.synchronize do
        @running = true
        @context = context
        @controller = controller
        @sink = sink
        @thread = Thread.current
        @ended = false
        @input_waiting = input_waiting
        @input_waiting_warned = false
        @steers.concat(@carried_steers)
        @carried_steers = []
      end
    end

    # The turn is over: not running, no context, controller, sink, probe or
    # steers. Its context stays as the last one (#last_context); one that
    # never got its settings (a turn stopped before Engine#generate) keeps
    # the last settings there, as the kernel kept the last turn's before.
    # @return [Array<Hash>] the steers it never took ({text:, source:})
    def finish!
      @lock.synchronize do
        if @context
          settings = @context.settings || @last_context&.settings
          @last_context = settings.equal?(@context.settings) ? @context : @context.with(settings: settings)
        end
        @context = nil
        @running = false
        @controller = nil
        @sink = nil
        @thread = nil
        @ended = false
        @input_waiting = nil
        @steers.tap { @steers = [] }
      end
    end

    # The turn's end is decided (its end event is out): what runs after,
    # its after_turn / session_end hooks, is post-turn work, up to #finish!.
    def ended!
      @lock.synchronize { @ended = true }
    end

    # @return [TurnContext, nil] the running turn's context (nil between
    #   turns); its settings are nil until Engine#generate
    def context
      @lock.synchronize { @context }
    end

    # @return [TurnContext, nil] the last finished turn's context (nil
    #   before any), kept while the next turn runs
    def last_context
      @lock.synchronize { @last_context }
    end

    # The turn thread's new context for its running turn (Engine#generate's
    # settings): one assignment of a frozen value. Only the turn's own
    # thread, and only for the same turn.
    # @param context [TurnContext]
    # @raise [ArgumentError] from another thread, outside a turn, or for
    #   another turn's context
    def replace_context(context)
      @lock.synchronize do
        raise ArgumentError, "no turn runs on this thread" unless @running && @thread.equal?(Thread.current)
        raise ArgumentError, "not the running turn's context" unless @context.nil? || @context.id == context.id

        @context = context
      end
    end

    # @return [CancellationController, nil] the running turn's controller
    def controller
      @lock.synchronize { @controller }
    end

    # The controller for work done for the turn itself (a plugin's HTTP
    # call): the running turn's, on the turn's thread or +handler+ (inside a
    # plugin's event handler, whatever thread fires it), until the turn has
    # ended; nil for any other thread (an anytime command, a service) and
    # outside a turn.
    # @return [CancellationController, nil]
    def own_controller(handler: false)
      @lock.synchronize do
        return nil unless @running && !@ended

        handler || @thread.equal?(Thread.current) ? @controller : nil
      end
    end

    # @return [#call, nil] the running turn's input_waiting probe (called
    #   outside the lock), nil outside a turn or for a turn given none
    def input_waiting
      @lock.synchronize { @running ? @input_waiting : nil }
    end

    # A probe failed: true the first time in a turn (warn then), false after.
    def input_waiting_failed!
      @lock.synchronize { !@input_waiting_warned.tap { @input_waiting_warned = true } }
    end

    # Cancel the running turn, if any (the controller is taken, and the turn
    # id compared, under the lock; it is cancelled outside it).
    # @param turn_id [String, nil] the turn the caller means: another turn
    #   running (a Stop that arrived as its turn ended) is left alone; nil
    #   cancels whichever runs
    # @return [Boolean, Symbol] whether a cancellation was triggered, or
    #   :turn_mismatch when +turn_id+ is not the running turn's
    def cancel!(reason, turn_id: nil)
      ctrl = @lock.synchronize do
        next nil unless @controller
        next :mismatch if turn_id && @context&.id != turn_id

        @controller
      end
      return false unless ctrl
      return :turn_mismatch if ctrl == :mismatch

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
