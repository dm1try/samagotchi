# frozen_string_literal: true

require "samagotchi/idle_reminders"

RSpec.describe Samagotchi::IdleReminders do
  subject(:idle_reminders) do
    described_class.new(
      engine: engine,
      reminder_store: reminder_store,
      inactivity: 60.0,
      clock: clock
    )
  end

  let(:engine) { double("Engine") }
  let(:reminder_store) { Samagotchi::ReminderStore.new }
  let(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }

  before do
    allow(engine).to receive(:turn_running?).and_return(false)
    allow(engine).to receive(:last_activity_at).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) - 70)
  end

  describe "#due_reminders" do
    it "returns due reminders from the reminder store" do
      reminder_store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      due = idle_reminders.due_reminders
      expect(due.map { |r| r[:name] }).to include("health")
    end

    it "returns empty array when no reminders are due" do
      expect(idle_reminders.due_reminders).to eq([])
    end

    it "returns empty array when reminder_store is nil" do
      idle_reminders = described_class.new(
        engine: engine,
        reminder_store: nil,
        clock: clock
      )
      expect(idle_reminders.due_reminders).to eq([])
    end
  end

  describe "#tick" do
    it "sets @due_reminder_name when a reminder is due" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      expect(idle_reminders.due_reminder_name).to eq("health")
    end

    it "does not set @due_reminder_name when no reminder is due" do
      idle_reminders.tick
      expect(idle_reminders.due_reminder_name).to be_nil
    end

    it "does not fire if already has a pending due reminder" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      idle_reminders.tick
      # Should still be "health", not nil or something else
      expect(idle_reminders.due_reminder_name).to eq("health")
    end

    it "does not fire if turn is running" do
      allow(engine).to receive(:turn_running?).and_return(true)
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      expect(idle_reminders.due_reminder_name).to be_nil
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
        reminder_store: reminder_store,
        inactivity: 60.0,
        clock: clock
      )
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      idle_reminders.tick
      expect(idle_reminders.due_reminder_name).to be_nil
    end
  end

  describe "#clear_due" do
    it "clears the pending due reminder" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      expect(idle_reminders.due_reminder_name).to eq("health")
      idle_reminders.clear_due
      expect(idle_reminders.due_reminder_name).to be_nil
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
