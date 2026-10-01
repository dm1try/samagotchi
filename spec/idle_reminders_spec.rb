# frozen_string_literal: true

require "samagotchi/idle_reminders"
require "samagotchi/reminder_store"

RSpec.describe Samagotchi::IdleReminders do
  subject(:idle_reminders) do
    described_class.new(
      engine: engine,
      queue: Samagotchi::ReminderQueue.new(store: reminder_store),
      inactivity: 60.0,
      clock: clock,
      callback: ->(names) { fired << names }
    )
  end

  # The due names each synthetic-turn callback got.
  let(:fired) { [] }

  let(:engine) { double("Engine") }
  let(:reminder_store) { Samagotchi::ReminderStore.new }
  let(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }

  before do
    allow(engine).to receive(:turn_running?).and_return(false)
    allow(engine).to receive(:last_activity_at).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) - 70)
  end

  describe "#tick" do
    it "fires the callback with the due names when a reminder is due" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      expect(fired).to eq([["health"]])
    end

    it "does not fire when no reminder is due" do
      idle_reminders.tick
      expect(fired).to be_empty
    end

    it "does not fire if already has a pending due reminder" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      idle_reminders.tick
      # Latched until the engine delivers it (#clear_due).
      expect(fired).to eq([["health"]])
    end

    it "does not fire if turn is running" do
      allow(engine).to receive(:turn_running?).and_return(true)
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      expect(fired).to be_empty
    end

    it "does not fire if not idle long enough" do
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      engine_mock = double("Engine")
      allow(engine_mock).to receive(:turn_running?).and_return(false)
      # last_activity_at = now, so idle = clock.call - now = 0
      allow(engine_mock).to receive(:last_activity_at).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      )
      idle_reminders = described_class.new(
        engine: engine_mock,
        queue: Samagotchi::ReminderQueue.new(store: reminder_store),
        inactivity: 60.0,
        clock: clock,
        callback: ->(names) { fired << names }
      )
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      idle_reminders.tick
      expect(fired).to be_empty
    end
  end

  describe "#clear_due" do
    it "clears the latch, so the next tick fires again" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      idle_reminders.tick
      expect(fired).to eq([["health"]])
      idle_reminders.clear_due
      idle_reminders.tick
      expect(fired).to eq([["health"], ["health"]])
    end
  end

  describe "#should_check?" do
    it "returns true when idle and turn not running" do
      expect(idle_reminders.send(:should_check?)).to be true
    end

    it "returns false when turn is running" do
      allow(engine).to receive(:turn_running?).and_return(true)
      expect(idle_reminders.send(:should_check?)).to be false
    end

    it "returns false when not idle enough" do
      allow(engine).to receive(:last_activity_at).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      )
      expect(idle_reminders.send(:should_check?)).to be false
    end
  end
end
