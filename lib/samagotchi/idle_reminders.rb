# frozen_string_literal: true

require "monitor"

require_relative "reminder_store"

module Samagotchi
  # Engine-owned idle detector for periodic reminders.
  #
  # In the pull-based model, the background thread polls but does NOT set
  # @due_reminder_name — Engine#maybe_inject_reminders / collect_due_reminders
  # reads directly from ReminderStore#due_reminders. The thread exists as a
  # no-op hook in case push-based auto-turn is re-enabled later.
  #
  # Communication pattern (pull-based):
  #   Engine#run_turn: collect_due_reminders reads ReminderStore#due_reminders
  #   → injects [SYSTEM: REMINDERS DUE] → marks all as fired atomically
  class IdleReminders
    POLL_INTERVAL_SECONDS = 0.5
    DEFAULT_MIN_INACTIVITY_SECONDS = 60.0 # Minimum idle time before checking for reminders

    attr_reader :inactivity

    def initialize(engine:, inactivity: DEFAULT_MIN_INACTIVITY_SECONDS,
                   reminder_store: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise ArgumentError, "IdleReminders requires an engine" unless engine

      @engine = engine
      @inactivity = inactivity
      @reminder_store = reminder_store || engine.instance_variable_get(:@reminder_store)
      @clock = clock

      @mutex = Monitor.new
      @due_reminder_name = nil
      @thread = nil
      @stopped = false
    end

    # Spawn the idle-detection thread (idempotent).
    def start
      return if running?

      @thread = Thread.new { run_loop }
      self
    end

    def running?
      !@thread.nil? && @thread.alive? && !@stopped
    end

    # Stop the idle-detection thread.
    def stop
      @stopped = true
      @thread&.kill
      @thread = nil
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

    # Clear the pending due reminder (after it has been delivered).
    # Called by Engine after injecting the reminder into the system prompt.
    def clear_due
      @mutex.synchronize { @due_reminder_name = nil }
    end

    # One detector step. Public so specs can drive it deterministically.
    def tick
      return if @stopped
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

    def run_loop
      loop do
        break if @stopped
        begin
          tick
        rescue StandardError => e
          warn "[IdleReminders] tick failed: #{e.class}: #{e.message}"
        end
        sleep(POLL_INTERVAL_SECONDS)
      end
    rescue StandardError => e
      warn "[IdleReminders] detector thread crashed: #{e.class}: #{e.message}"
    end

    def last_idle_seconds
      @clock.call - @engine.last_activity_at
    end

    def check_due_reminders
      return unless @reminder_store

      name = @reminder_store.next_due_name
      return unless name

      description = @reminder_store.get_description(name)
      return unless description

      # Signal the engine to create a synthetic turn
      @mutex.synchronize { @due_reminder_name = name }

      # If the engine is idle (no turn running), the engine's run_turn will
      # pick up the due reminder and inject it into the system prompt.
      # The engine does NOT auto-run a turn — the reminder waits for the next
      # natural pause (user input or background worker input).
    end
  end
end
