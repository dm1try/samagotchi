# frozen_string_literal: true

module Samagotchi
  # TERM, HUP and INT in a worker process: the running turn stops as a Stop
  # does (reason :signal), is saved, and the worker leaves (Worker#run
  # returns :signal). SessionManager.run_session_loop installs the traps in
  # a spawned worker only (WORKER_PROCESS_ENV), never in a process that runs
  # the loop in-process (the specs, which fire #fire directly).
  #
  # A trap handler may take no lock (Mutex#lock raises ThreadError in trap
  # context) and should do no IO: the trap only records the signal and
  # starts a thread, which calls the worker's handler (#on_signal).
  #
  # Ruby's default for these signals raised SignalException in the main
  # thread, mid-turn: the turn skipped every end-of-turn path and nothing of
  # it reached the session file.
  class WorkerSignals
    SIGNALS = %w[TERM HUP INT].freeze

    # Nothing trapped and nothing fires: Worker.new's default (specs, and
    # any caller that isn't a spawned worker).
    class None
      def on_signal(&) = nil
      def signal = nil
      def count = 0
      def hard_exit = nil
      def restore! = nil
    end
    NONE = None.new.freeze

    # @return [String, nil] the first signal received ("TERM"), nil before one
    attr_reader :signal

    # @param hard_exit [#call] the last resort when the worker hasn't left
    #   long after the signal (exit! in a real worker)
    def initialize(hard_exit: -> { Process.exit!(1) })
      @signal = nil
      @count = 0
      @handler = nil
      @hard_exit = hard_exit
      @previous = {}
    end

    # How many signals came (a second one skips the grace).
    attr_reader :count

    # The worker's handler, called on a thread of its own with the signal
    # name and the count, once per signal.
    def on_signal(&handler)
      @handler = handler
    end

    # Trap SIGNALS in this process (the previous handlers kept for #restore!).
    # @return [self]
    def install!
      SIGNALS.each { |name| @previous[name] = Signal.trap(name) { fire(name) } }
      self
    end

    # The handlers from before #install!.
    def restore!
      @previous.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
      @previous.clear
    end

    # What a trap does (and what specs call): record +name+ and run the
    # handler on its own thread. Safe in trap context: no lock, no IO.
    # @return [Thread, nil] the handler's thread
    def fire(name)
      @signal ||= name
      @count += 1
      handler = @handler
      count = @count
      return nil unless handler

      Thread.new { handler.call(name, count) }
    end

    def hard_exit = @hard_exit.call
  end
end
