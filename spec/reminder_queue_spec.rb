# frozen_string_literal: true

require "samagotchi/reminder_queue"
require "samagotchi/reminder_store"
require "samagotchi/session"
require "samagotchi/prompt"

RSpec.describe Samagotchi::ReminderQueue do
  subject(:queue) { described_class.new(store: store) }

  let(:store) { Samagotchi::ReminderStore.new }

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def make_due(*names)
    store.instance_variable_get(:@mutex).synchronize do
      names.each { |name| store.reminders[name][:next_fire_at] = now - 1 }
    end
  end

  describe "#due and #due?" do
    it "read the store" do
      store.register({ name: "health", description: "Check API", interval_minutes: 5 })
      expect([queue.due, queue.due?]).to eq([[], false])
      make_due("health")
      expect(queue.due).to eq([{ name: "health", description: "Check API", interval_minutes: 5 }])
      expect(queue.due?).to be(true)
    end

    it "are empty with no store" do
      queue = described_class.new(store: nil)
      expect([queue.due, queue.due?]).to eq([[], false])
      expect(queue.inject!([])).to eq([])
    end
  end

  describe "the pending names" do
    it "are set by note_pending (a copy), read as a copy and cleared" do
      names = ["tea"]
      queue.note_pending(names)
      names << "x"
      queue.pending_names << "y"
      expect(queue.pending_names).to eq(["tea"])
      queue.clear_pending!
      expect(queue.pending_names).to eq([])
    end
  end

  describe "#inject!" do
    let(:messages) { [{ role: "system", content: "You are Chi." }, { role: "user", content: "hello" }] }

    it "with no reminders: returns [] and leaves the messages alone" do
      expect(queue.inject!(messages)).to eq([])
      expect(messages.size).to eq(2)
    end

    it "with a reminder not yet due: returns [] and keeps the pending names" do
      store.register({ name: "health", description: "Check API", interval_minutes: 5 })
      queue.note_pending(["health"])
      expect(queue.inject!(messages)).to eq([])
      expect(queue.pending_names).to eq(["health"])
    end

    it "appends one tail system message, leaving the head alone (the prefix cache)" do
      store.register({ name: "health", description: "Check API health", interval_minutes: 1 })
      make_due("health")

      result = queue.inject!(messages)

      expect(result.map { |r| r[:name] }).to eq(["health"])
      expect(messages.first[:content]).to eq("You are Chi.")
      expect(messages.size).to eq(3)
      expect(messages.last).to eq(role: "system", at: message_at,
                                  content: "[SYSTEM: REMINDERS DUE 2026-01-02 03:04 local]\n  health: Check API health (interval: 1m)\n[END REMINDERS]")
    end

    it "names the time the reminders came due in the header, the turn's time when given, its zone's clock" do
      store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      make_due("health")
      messages = []

      queue.inject!(messages, now: Time.new(2026, 10, 24, 14, 32, 5, "+02:00"))

      expect(messages.last[:content]).to start_with("[SYSTEM: REMINDERS DUE 2026-10-24 14:32 local]\n  health:")
      expect(messages.last[:at]).to eq("2026-10-24T14:32:05.000+02:00")
    end

    it "keeps the header's time in the content: a saved and loaded session renders the same bytes later, elsewhere" do
      store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      make_due("health")
      messages = [{ role: "user", content: "hello" }]
      queue.inject!(messages)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
      session.messages = messages

      loaded = Samagotchi::Session.from_h(JSON.parse(JSON.generate(session.to_h)))
      Samagotchi::MessageTime.source = -> { Time.new(2027, 3, 30, 23, 59, 0, "+09:00") }

      with_env("TZ" => "Asia/Tokyo") do
        expect(loaded.messages.last[:content]).to eq(messages.last[:content])
        expect(Samagotchi::Prompt.format(loaded.messages)).to eq(Samagotchi::Prompt.format(messages))
      end
    end

    it "appends to a conversation with no system message too" do
      store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      make_due("health")
      messages = [{ role: "user", content: "hello" }]
      queue.inject!(messages)
      expect(messages.last[:role]).to eq("system")
      expect(messages.size).to eq(2)
    end

    it "marks them fired and clears the pending names" do
      store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      make_due("health")
      queue.note_pending(["health"])

      queue.inject!(messages)

      expect(store.reminders["health"][:next_fire_at]).to be > now + 30
      expect(queue.pending_names).to eq([])
      expect(queue.due?).to be(false)
    end

    it "injects every due reminder in one message" do
      store.register({ name: "health", description: "Check API", interval_minutes: 1 })
      store.register({ name: "cleanup", description: "Clean temp files", interval_minutes: 1 })
      make_due("health", "cleanup")
      messages = [{ role: "system", content: "You are Chi." }]

      result = queue.inject!(messages)

      expect(result.map { |r| r[:name] }).to match_array(%w[health cleanup])
      expect(messages.last[:content]).to include("health: Check API", "cleanup: Clean temp files")
      expect(messages.size).to eq(2)
    end
  end
end
