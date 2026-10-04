# frozen_string_literal: true

require "samagotchi/reminder_store"

RSpec.describe Samagotchi::ReminderStore do
  subject(:store) { described_class.new }

  describe "#any?" do
    it "tells whether any reminder is registered" do
      expect(store.any?).to be(false)
      store.register({ name: "health", description: "Check API", interval_minutes: 5 })
      expect(store.any?).to be(true)
      store.cancel("health")
      expect(store.any?).to be(false)
    end
  end

  describe "#register" do
    it "registers a reminder and returns confirmation" do
      result = store.register({ name: "health", description: "Check API", interval_minutes: 5 })
      expect(result).to include("Reminder 'health' registered")
      expect(result).to include("interval: 5m")
    end

    it "rejects empty name" do
      result = store.register({ name: "", description: "test", interval_minutes: 1 })
      expect(result).to eq("Error: name is required")
    end

    it "rejects empty description" do
      result = store.register({ name: "health", description: "", interval_minutes: 1 })
      expect(result).to eq("Error: description is required")
    end

    it "rejects interval < 1" do
      result = store.register({ name: "health", description: "test", interval_minutes: 0 })
      expect(result).to eq("Error: interval_minutes must be >= 1")
    end

    it "rejects interval > 1440" do
      result = store.register({ name: "health", description: "test", interval_minutes: 2000 })
      expect(result).to eq("Error: interval_minutes must be <= 1440")
    end

    it "coerces interval_minutes to integer" do
      result = store.register({ name: "health", description: "test", interval_minutes: "10" })
      expect(result).to include("interval: 10m")
    end

    it "stores with correct fields" do
      store.register({ name: "health", description: "Check API health", interval_minutes: 5 })
      r = store.reminders["health"]
      expect(r[:name]).to eq("health")
      expect(r[:description]).to eq("Check API health")
      expect(r[:interval_minutes]).to eq(5)
      expect(r[:id]).not_to be_nil
      expect(r[:next_fire_at]).to be > r[:last_fire_at]
    end
  end

  describe "#cancel" do
    it "cancels an existing reminder" do
      store.register({ name: "health", description: "test", interval_minutes: 5 })
      result = store.cancel("health")
      expect(result).to eq("Reminder 'health' canceled.")
      expect(store.reminders).to be_empty
    end

    it "returns error for non-existent reminder" do
      result = store.cancel("nonexistent")
      expect(result).to eq("Error: no such reminder 'nonexistent'.")
    end
  end

  describe "#list" do
    it "returns formatted list of active reminders" do
      store.register({ name: "health", description: "test", interval_minutes: 5 })
      store.register({ name: "cleanup", description: "test", interval_minutes: 10 })
      output = store.list
      expect(output).to include("Active reminders:")
      expect(output).to include("health")
      expect(output).to include("cleanup")
    end

    it "returns no reminders message when empty" do
      expect(store.list).to eq("No active reminders.")
    end
  end

  describe "#due_reminders" do
    it "returns empty array when no reminders are due" do
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1000 }
      store = described_class.new
      store.instance_variable_set(:@clock, clock)
      # Override the clock used by due_reminders
      allow(Process).to receive(:clock_gettime).and_return(clock.call)
      expect(store.due_reminders).to eq([])
    end

    it "returns due reminders when interval has elapsed" do
      store.register({ name: "health", description: "Check API health", interval_minutes: 1 })
      # Fast-forward time past the next_fire_at
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      due = store.due_reminders
      expect(due).to be_an(Array)
      expect(due.map { |r| r[:name] }).to include("health")
      expect(due.map { |r| r[:description] }).to include("Check API health")
      expect(due.map { |r| r[:interval_minutes] }).to include(1)
    end

    it "returns ALL due reminders, not just one" do
      store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      store.register({ name: "cleanup", description: "Clean temp files", interval_minutes: 1 })
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      due = store.due_reminders
      expect(due.map { |r| r[:name] }).to match_array(%w[health cleanup])
    end

    it "returns frozen array" do
      allow(Process).to receive(:clock_gettime).and_return(
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 70
      )
      store.register({ name: "health", description: "test", interval_minutes: 1 })
      due = store.due_reminders
      expect { due << { name: "other" } }.to raise_error(FrozenError)
    end
  end

  describe "#mark_fired" do
    it "resets next_fire_at" do
      store.register({ name: "health", description: "test", interval_minutes: 5 })
      old_next = store.reminders["health"][:next_fire_at]
      store.mark_fired("health")
      new_next = store.reminders["health"][:next_fire_at]
      expect(new_next).to be > old_next
      expect(store.reminders["health"][:last_fire_at]).not_to be_nil
    end
  end

  describe "#mark_fired_batch" do
    it "marks multiple reminders as fired" do
      store.register({ name: "health", description: "test", interval_minutes: 5 })
      store.register({ name: "cleanup", description: "test", interval_minutes: 10 })
      old_health = store.reminders["health"][:next_fire_at]
      old_cleanup = store.reminders["cleanup"][:next_fire_at]
      store.mark_fired_batch(%w[health cleanup])
      expect(store.reminders["health"][:next_fire_at]).to be > old_health
      expect(store.reminders["cleanup"][:next_fire_at]).to be > old_cleanup
    end
  end

  describe "#get_description" do
    it "returns the description for an existing reminder" do
      store.register({ name: "health", description: "Check API", interval_minutes: 5 })
      expect(store.get_description("health")).to eq("Check API")
    end

    it "returns nil for non-existent reminder" do
      expect(store.get_description("nonexistent")).to be_nil
    end
  end

  describe "#clear_all" do
    it "removes all reminders" do
      store.register({ name: "health", description: "test", interval_minutes: 5 })
      store.register({ name: "cleanup", description: "test", interval_minutes: 10 })
      store.clear_all
      expect(store.reminders).to be_empty
    end
  end

  describe "thread safety" do
    it "handles concurrent registration and due_reminders" do
      store.register({ name: "health", description: "test", interval_minutes: 1 })
      threads = 10.times.map do |i|
        Thread.new do
          store.due_reminders
          store.mark_fired("health") if i.even?
        end
      end
      threads.each(&:join)
      # Should not raise any errors
    end
  end
end
