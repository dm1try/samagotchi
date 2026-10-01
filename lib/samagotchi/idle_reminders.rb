# frozen_string_literal: true

require "monitor"

require_relative "reminder_queue"

module Samagotchi
  # Idle job for periodic reminders — polled by the shared IdleScheduler
  # (one background thread for the whole idle layer).
  #
  # Two delivery paths cooperate:
  #   1. Every turn injects what is due (ReminderQueue#inject!, from
  #      Engine#run_turn) as [SYSTEM: REMINDERS DUE] and marks it fired.
  #   2. Synthetic turns: when this job's tick finds due reminders while
  #      idle, it latches @due_reminder_name and fires @auto_turn_callback
  #      (the worker and the REPL queue a reminder turn).
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

      @mutex = Monitor.new
      @due_reminder_name = nil
    end

    # Clear the pending due reminder (after it has been delivered).
    # Called by Engine after a turn injected the due reminders.
    def clear_due
      @mutex.synchronize { @due_reminder_name = nil }
    end

    # One detector step, called by the shared IdleScheduler. Public so specs
    # can drive it deterministically.
    def tick
      return if @due_reminder_name # already due, waiting for engine to deliver
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
      @mutex.synchronize { @due_reminder_name = due_names.first }
      if @auto_turn_callback
        @auto_turn_callback.call(due_names)
      end
    end
  end
end
