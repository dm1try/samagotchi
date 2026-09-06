# frozen_string_literal: true

require "monitor"

require_relative "reminder_store"

module Samagotchi
  # Idle job for periodic reminders — polled by the shared IdleScheduler
  # (one background thread for the whole idle layer).
  #
  # Two delivery paths cooperate:
  #   1. Pull-based: Engine#maybe_inject_reminders / collect_due_reminders
  #      reads ReminderStore#due_reminders at turn start → injects
  #      [SYSTEM: REMINDERS DUE] → marks all as fired atomically.
  #   2. Synthetic turns: when this job's tick finds due reminders while
  #      idle, it latches @due_reminder_name and fires @auto_turn_callback
  #      (the TUI/SessionManager queue a synthetic turn from the latch).
  class IdleReminders
    DEFAULT_MIN_INACTIVITY_SECONDS = 60.0 # Minimum idle time before checking for reminders

    attr_reader :inactivity

    def initialize(engine:, inactivity: DEFAULT_MIN_INACTIVITY_SECONDS,
                   reminder_store: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   callback: nil)
      raise ArgumentError, "IdleReminders requires an engine" unless engine

      @engine = engine
      @inactivity = inactivity
      @reminder_store = reminder_store || engine.instance_variable_get(:@reminder_store)
      @clock = clock
      @auto_turn_callback = callback

      @mutex = Monitor.new
      @due_reminder_name = nil
    end

    # Get the currently pending due reminder name (for Engine to read).
    # Kept for backward compatibility.
    # Called by Engine#collect_due_reminders. Thread-safe.
    def due_reminder_name
      @mutex.synchronize { @due_reminder_name }
    end

    # Get all due reminders (from ReminderStore). Called by Engine#maybe_inject_reminders.
    # Thread-safe. Returns all due reminders, not just one.
    # @return [Array<Hash>] [{name:, description:, interval_minutes:}, ...]
    def due_reminders
      @reminder_store&.due_reminders || []
    end
    # Get the names of all due reminders. Called by the background thread to
    # determine which reminders need a synthetic turn.
    # @return [Array<String>] reminder names that are due
    def due_reminder_names
      due_reminders.map { |r| r[:name] }
    end

    # Clear the pending due reminder (after it has been delivered).
    # Called by Engine after injecting the reminder into the system prompt.
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
      return unless @reminder_store
      due_names = @reminder_store.due_reminders.map { |r| r[:name] }
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
