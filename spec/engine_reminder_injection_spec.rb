# frozen_string_literal: true
require "samagotchi/engine"
require "samagotchi/session"
RSpec.describe Samagotchi::Engine do
  describe "#collect_due_reminders" do
    let(:engine) { described_class.new(mode: :assist, profile: :gemma4) }
    let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd) }
    before do
      engine.start_idle
      engine.instance_variable_set(:@session, session)
    end
    after do
      engine.stop_idle
      engine.reminder_store&.clear_all
    end
    describe "when no reminders are registered" do
      it "returns empty array and does not modify messages" do
        messages = [{ role: "system", content: "You are Chi." }, { role: "user", content: "hello" }]
        result = engine.collect_due_reminders(messages)
        expect(result).to eq([])
        expect(messages).to eq([{ role: "system", content: "You are Chi." }, { role: "user", content: "hello" }])
      end
    end
    describe "when a reminder is registered but not yet due" do
      it "returns empty array" do
        engine.reminder_store.register({ name: "health", description: "Check API", interval_minutes: 5 })
        result = engine.collect_due_reminders([{ role: "system", content: "You are Chi." }])
        expect(result).to eq([])
      end
    end
    describe "when a reminder is due" do
      it "appends a tail system message and returns due reminders (preserves prefix cache)" do
        engine.reminder_store.register({ name: "health", description: "Check API health", interval_minutes: 1 })
        # Fast-forward: set next_fire_at to the past
        engine.reminder_store.instance_variable_get(:@mutex).synchronize do
          engine.reminder_store.reminders["health"][:next_fire_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
        end
        messages = [{ role: "system", content: "You are Chi." }, { role: "user", content: "hello" }]
        original_first = messages.first[:content].dup
        result = engine.collect_due_reminders(messages)
        expect(result).to be_an(Array)
        expect(result.map { |r| r[:name] }).to include("health")
        expect(result.map { |r| r[:description] }).to include("Check API health")
        # Head must be untouched to preserve KV cache prefix
        expect(messages.first[:content]).to eq(original_first)
        expect(messages.last[:role]).to eq("system")
        expect(messages.last[:content]).to include("[SYSTEM: REMINDERS DUE]")
        expect(messages.last[:content]).to include("health: Check API health")
        expect(messages.size).to eq(3)
      end
      it "appends a tail system message even when none exists (no head mutation)" do
        engine.reminder_store.register({ name: "health", description: "Check API", interval_minutes: 1 })
        engine.reminder_store.instance_variable_get(:@mutex).synchronize do
          engine.reminder_store.reminders["health"][:next_fire_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
        end
        messages = [{ role: "user", content: "hello" }]
        engine.collect_due_reminders(messages)
        expect(messages.last[:role]).to eq("system")
        expect(messages.last[:content]).to include("[SYSTEM: REMINDERS DUE]")
        expect(messages.size).to eq(2)
      end
      it "marks reminders as fired" do
        engine.reminder_store.register({ name: "health", description: "Check API", interval_minutes: 1 })
        engine.reminder_store.instance_variable_get(:@mutex).synchronize do
          engine.reminder_store.reminders["health"][:next_fire_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
        end
        engine.collect_due_reminders([{ role: "system", content: "test" }])
        r = engine.reminder_store.reminders["health"]
        expect(r[:next_fire_at]).to be > Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      end
    end
    describe "when multiple reminders are due" do
      it "injects all due reminders as one tail message" do
        engine.reminder_store.register({ name: "health", description: "Check API", interval_minutes: 1 })
        engine.reminder_store.register({ name: "cleanup", description: "Clean temp files", interval_minutes: 1 })
        engine.reminder_store.instance_variable_get(:@mutex).synchronize do
          engine.reminder_store.reminders.each_value do |r|
            r[:next_fire_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
          end
        end
        messages = [{ role: "system", content: "You are Chi." }]
        result = engine.collect_due_reminders(messages)
        expect(result.map { |r| r[:name] }).to match_array(["health", "cleanup"])
        expect(messages.last[:content]).to include("health: Check API")
        expect(messages.last[:content]).to include("cleanup: Clean temp files")
        expect(messages.size).to eq(2)
      end
    end
  end
end