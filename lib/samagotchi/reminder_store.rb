# frozen_string_literal: true

require "monitor"
require "securerandom"
require "time"

module Samagotchi
  # Thread-safe store for periodic reminders registered by the agent.
  #
  # The agent registers reminders via the `register_reminder` tool during a
  # turn. The `IdleReminders` detector thread polls this store to find due
  # reminders and signals the Engine to auto-create a turn when one is due.
  #
  # The store is owned by the Engine and injected into KernelLoop so both
  # loops (native and chat) use the same dispatch path for tool calls.
  #
  # Reminder lifecycle:
  #   1. Agent calls register_reminder → store adds entry
  #   2. IdleReminders detects due while idle → the UI queues a reminder turn
  #   3. Engine#run_turn injects what is due as a [SYSTEM:] message (ReminderQueue#inject!)
  #   4. Agent acts on reminder → calls cancel_reminder → store removes entry
  class ReminderStore
    # @return [Hash{String => Hash}] id => {id:, name:, description:, interval_minutes:, next_fire_at:}
    attr_reader :reminders

    def initialize
      @mutex = Monitor.new
      @reminders = {}
    end

    # Register a new reminder.
    # @param call [Hash] the tool call params (from the model)
    # @return [String] confirmation message
    def register(call)
      name = (call[:name] || call[:content]).to_s.strip
      description = (call[:description] || "").to_s.strip
      interval = (call[:interval_minutes] || 1).to_i

      return "Error: name is required" if name.empty?
      return "Error: description is required" if description.empty?
      return "Error: interval_minutes must be >= 1" if interval < 1
      return "Error: interval_minutes must be <= 1440" if interval > 1440

      id = SecureRandom.hex(6)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        @reminders[name] = {
          id: id,
          name: name,
          description: description,
          interval_minutes: interval,
          last_fire_at: now,
          next_fire_at: now + (interval * 60)
        }
      end

      "Reminder '#{name}' registered (interval: #{interval}m, id: #{id})."
    end

    # Cancel a reminder by name.
    # @param name [String] the reminder name to cancel
    # @return [String] result message
    def cancel(name)
      name = name.to_s.strip
      @mutex.synchronize do
        if @reminders.delete(name)
          "Reminder '#{name}' canceled."
        else
          "Error: no such reminder '#{name}'."
        end
      end
    end

    # @return [Boolean] whether any reminder is registered
    def any?
      @mutex.synchronize { !@reminders.empty? }
    end

    # List all active reminders.
    # @return [String] formatted list
    def list
      @mutex.synchronize do
        return "No active reminders." if @reminders.empty?

        lines = @reminders.map do |_name, r|
          "  #{r[:name]} (interval: #{r[:interval_minutes]}m, id: #{r[:id]})"
        end
        "Active reminders:\n" + lines.join("\n")
      end
    end

    # Get all due reminders whose interval has elapsed.
    # Returns an Array of {name:, description:, interval_minutes:} hashes.
    # Read by ReminderQueue (a turn's injection, the idle tick).
    # Thread-safe. Returns a frozen copy so the caller can't mutate internal state.
    # @return [Array<Hash>] array of due reminder hashes (may be empty)
    def due_reminders
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        @reminders.each_value.filter_map do |r|
          next unless r[:next_fire_at] && now >= r[:next_fire_at]

          { name: r[:name], description: r[:description], interval_minutes: r[:interval_minutes] }
        end.freeze
      end
    end

    # Mark multiple reminders as fired — resets each next_fire_at to now + interval.
    # Called by Engine after injecting multiple due reminders (batch operation).
    # Thread-safe, single lock acquisition.
    # @param names [Array<String>] reminder names to mark as fired
    def mark_fired_batch(names)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        names.each do |name|
          name = name.to_s.strip
          r = @reminders[name]
          if r
            r[:last_fire_at] = now
            r[:next_fire_at] = now + (r[:interval_minutes] * 60)
          end
        end
      end
    end

    # The reminders as a restart hands them to the next worker (ReminderCarry):
    # each one's id, name, description and interval, and its next fire as
    # wall-clock ISO time, since the monotonic clock doesn't cross processes.
    # @return [Array<Hash{String => Object}>]
    def export(wall: Time.now, mono: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      @mutex.synchronize do
        @reminders.each_value.map do |r|
          { "id" => r[:id], "name" => r[:name], "description" => r[:description],
            "interval_minutes" => r[:interval_minutes],
            "next_fire_at" => (wall + (r[:next_fire_at] - mono)).utc.iso8601(3) }
        end
      end
    end

    # Take back what #export wrote in another process. A reminder keeps its
    # id and schedule: one overdue is due now (once, no catch-up), one further
    # ahead than its interval (a clock that jumped) is due one interval from
    # now. An entry #register would refuse, or with no time, is skipped.
    # @param entries [Array<Hash>] #export's, parsed from JSON
    # @return [Array<String>] the names restored
    def restore(entries, wall: Time.now, mono: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return [] unless entries.is_a?(Array)

      restored = entries.filter_map { |entry| restored_entry(entry, wall, mono) }
      @mutex.synchronize { restored.each { |r| @reminders[r[:name]] = r } }
      restored.map { |r| r[:name] }
    end

    # Clear all reminders.
    # Called when the session ends or the engine is reset.
    def clear_all
      @mutex.synchronize { @reminders.clear }
    end

    private

    def restored_entry(entry, wall, mono)
      return nil unless entry.is_a?(Hash)

      name = entry["name"].to_s.strip
      description = entry["description"].to_s.strip
      interval = Integer(entry["interval_minutes"], exception: false)
      return nil if name.empty? || description.empty? || interval.nil? || !(1..1440).cover?(interval)

      next_wall = Time.iso8601(entry["next_fire_at"].to_s)
      period = interval * 60
      next_fire = mono + (next_wall - wall).clamp(0, period)
      id = entry["id"].is_a?(String) && !entry["id"].empty? ? entry["id"] : SecureRandom.hex(6)
      { id: id, name: name, description: description, interval_minutes: interval,
        last_fire_at: next_fire - period, next_fire_at: next_fire }
    rescue ArgumentError
      nil
    end
  end
end
