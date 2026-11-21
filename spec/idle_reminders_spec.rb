# frozen_string_literal: true

require "samagotchi/idle_reminders"
require "samagotchi/reminder_store"
require "samagotchi/turn_state"

RSpec.describe Samagotchi::IdleReminders do
  subject(:idle_reminders) do
    described_class.new(
      turn_state: turn_state,
      queue: queue,
      inactivity: 60.0,
      clock: clock,
      # As the worker's does (Engine#note_due_reminders).
      callback: lambda { |names|
        fired << names
        queue.note_pending(names)
      }
    )
  end

  # The due names each synthetic-turn callback got.
  let(:fired) { [] }
  let(:queue) { Samagotchi::ReminderQueue.new(store: reminder_store) }

  let(:turn_state) { instance_double(Samagotchi::TurnState) }
  let(:reminder_store) { Samagotchi::ReminderStore.new }
  let(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }

  before do
    allow(turn_state).to receive(:running?).and_return(false)
    allow(turn_state).to receive(:last_activity_at).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) - 70)
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
      # Queued until a turn delivers it, or the reminder turn's consumer clears it.
      expect(fired).to eq([["health"]])
      expect(queue.pending_names).to eq(["health"])
    end

    it "does not fire if turn is running" do
      allow(turn_state).to receive(:running?).and_return(true)
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      expect(fired).to be_empty
    end

    it "does not fire if not idle long enough" do
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      idle_turn = instance_double(Samagotchi::TurnState)
      allow(idle_turn).to receive(:running?).and_return(false)
      # last_activity_at = now, so idle = clock.call - now = 0
      allow(idle_turn).to receive(:last_activity_at).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      )
      idle_reminders = described_class.new(
        turn_state: idle_turn,
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

  describe "the queue's pending names (the latch)" do
    it "cleared, re-arm the tick: it fires again while still due" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      idle_reminders.tick
      idle_reminders.tick
      expect(fired).to eq([["health"]])
      queue.clear_pending!
      idle_reminders.tick
      expect(fired).to eq([["health"], ["health"]])
    end

    it "cleared by a turn's injection, re-arm the tick for the next interval" do
      reminder_store.register({ name: "health", description: "test", interval_minutes: 1 })
      later = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      allow(Process).to receive(:clock_gettime).and_return(later)
      idle_reminders.tick
      queue.inject!([])
      idle_reminders.tick
      expect(fired).to eq([["health"]])

      allow(Process).to receive(:clock_gettime).and_return(later + 70)
      idle_reminders.tick
      expect(fired).to eq([["health"], ["health"]])
    end
  end

  describe "#should_check?" do
    it "returns true when idle and turn not running" do
      expect(idle_reminders.send(:should_check?)).to be true
    end

    it "returns false when turn is running" do
      allow(turn_state).to receive(:running?).and_return(true)
      expect(idle_reminders.send(:should_check?)).to be false
    end

    it "returns false when not idle enough" do
      allow(turn_state).to receive(:last_activity_at).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      )
      expect(idle_reminders.send(:should_check?)).to be false
    end
  end
end
