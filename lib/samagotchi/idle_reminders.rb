# frozen_string_literal: true

require_relative "reminder_queue"

module Samagotchi
  # Idle job for periodic reminders — polled by the shared IdleScheduler
  # (one background thread for the whole idle layer).
  #
  # Two delivery paths cooperate:
  #   1. Every turn injects what is due (ReminderQueue#inject!, from
  #      Engine#run_turn) as [SYSTEM: REMINDERS DUE] and marks it fired.
  #   2. Synthetic turns: when this job's tick finds due reminders while
  #      idle, it fires @auto_turn_callback, which queues their names
  #      (Engine#note_due_reminders) for the worker's or the REPL's
  #      reminder turn. While names are queued the tick waits; whoever
  #      clears them (a turn's injection, the reminder turn's consumer)
  #      re-arms it. The queue is the only "already due" state.
  class IdleReminders
    DEFAULT_MIN_INACTIVITY_SECONDS = 60.0 # Minimum idle time before checking for reminders

    attr_reader :inactivity

    def initialize(engine:, inactivity: DEFAULT_MIN_INACTIVITY_SECONDS,
                   queue: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   callback: nil)
      raise ArgumentError, "IdleReminders requires an engine" unless engine

      @engine = engine
      @inactivity = inactivity
      @queue = queue
      @clock = clock
      @auto_turn_callback = callback
    end

    # One detector step, called by the shared IdleScheduler. Public so specs
    # can drive it deterministically.
    def tick
      return if @queue&.pending? # already queued, waiting for a turn to deliver it
      return unless should_check?

      check_due_reminders
    end

    # @return [Boolean] true when it's time to check for reminders.
    def should_check?
      return false if @engine.turn_running?
      return false unless last_idle_seconds >= @inactivity

      true
    end

    private

    def last_idle_seconds
      @clock.call - @engine.last_activity_at
    end

    def check_due_reminders
      return unless @queue

      due_names = @queue.due.map { |r| r[:name] }
      return if due_names.empty?

      # Signal the engine to create a synthetic turn via callback.
      # The callback is responsible for triggering a turn (e.g. SessionManager
      # writes a file, TerminalUI queues input). The engine's run_turn or
      # REPL injection point then picks up and delivers the reminders.
      return unless @auto_turn_callback

      @auto_turn_callback.call(due_names)
    end
  end
end
