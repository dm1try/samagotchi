# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

# Due reminders end to end: the idle tick queues them (as the worker's
# callback does), a turn injects them, and the tick is armed again.
RSpec.describe Samagotchi::Engine, "reminders" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:fired) { [] }
  let(:engine) do
    fired_names = fired
    holder = {}
    built = described_class.new(client: client, kernel: kernel, profile: "gemma4",
                                 reminders: { callback: lambda { |names|
                                   fired_names << names
                                   holder[:engine].note_due_reminders(names)
                                 } })
    holder[:engine] = built
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:store) { engine.reminder_store }
  let(:idle) { engine.instance_variable_get(:@reminders) }
  let(:sent) { [] }
  let(:events) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do |messages, **|
      sent << messages.map(&:dup)
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
    engine.subscribe(observer: ->(event) { events << event })
    session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "before" }]
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def register(name = "tea")
    store.register({ name: name, description: "brew", interval_minutes: 1 })
  end

  # The reminder's interval has passed.
  def make_due(name = "tea")
    store.instance_variable_get(:@mutex).synchronize { store.reminders[name][:next_fire_at] = now - 1 }
  end

  # The session has been idle past the reminders' inactivity.
  def go_idle
    engine.record_activity(now - (idle.inactivity + 5))
  end

  def reminder_message?(message)
    message[:role] == "system" && message[:content].to_s.start_with?("[SYSTEM: REMINDERS DUE]")
  end

  describe "a due reminder in a turn" do
    before do
      register
      make_due
    end

    it "goes in as a tail system message after the history, before the user message" do
      engine.run_turn(session, "hi")

      roles = sent.last.map { |m| reminder_message?(m) ? "reminder" : "#{m[:role]}:#{m[:content].to_s[0, 8]}" }
      expect(roles.drop(1)).to eq(%w[user:earlier model:before reminder user:hi])
      expect(sent.last[-2][:content]).to eq("[SYSTEM: REMINDERS DUE]\n  tea: brew (interval: 1m)\n[END REMINDERS]")
    end

    it "emits reminder_injected, marks it fired and empties the queue" do
      engine.note_due_reminders(["tea"])

      engine.run_turn(session, "hi")

      injected = events.find { |e| e[:type] == :reminder_injected }
      expect(injected[:reminders]).to eq([{ name: "tea", description: "brew", interval_minutes: 1 }])
      expect(store.reminders["tea"][:next_fire_at]).to be > now + 30
      expect(engine.due_reminder_names).to eq([])
      expect(engine.reminders_due?).to be(false)
    end

    it "goes in on a continue turn too, with no user message" do
      engine.run_turn(session, nil, continue: true)

      expect(reminder_message?(sent.last.last)).to be(true)
      expect(sent.last.count { |m| m[:role] == "user" }).to eq(1)
    end
  end

  it "a turn with nothing due injects nothing and emits no reminder_injected" do
    register

    engine.run_turn(session, "hi")

    expect(sent.last.none? { |m| reminder_message?(m) }).to be(true)
    expect(events.map { |e| e[:type] }).not_to include(:reminder_injected)
  end

  it "the idle tick queues a due reminder, and fires again after a turn injected it" do
    register
    make_due
    go_idle

    idle.tick
    expect(fired).to eq([["tea"]])
    expect(engine.due_reminder_names).to eq(["tea"])
    expect(engine.reminders_due?).to be(true)

    # The worker's reminder turn (Worker#run_due_reminders).
    engine.clear_due_reminder_names!
    engine.run_turn(session, nil, continue: true)

    make_due
    go_idle
    idle.tick
    expect(fired).to eq([["tea"], ["tea"]])
  end

  describe "the stuck latch (cell B)" do
    it "today: a turn injecting between the tick's read and its latch leaves the tick silent for good" do
      register
      make_due
      go_idle
      in_between = false
      allow(store).to receive(:due_reminders).and_wrap_original do |original|
        due = original.call
        unless in_between
          in_between = true
          # The turn thread, between the idle tick's read and its latch.
          engine.run_turn(session, "hi")
        end
        due
      end

      idle.tick
      expect(fired).to eq([["tea"]]) # the stale name, queued
      expect(sent.last.count { |m| reminder_message?(m) }).to eq(1)

      # The consumer (Worker#run_due_reminders): stale, nothing to run.
      engine.clear_due_reminder_names!
      expect(engine.reminders_due?).to be(false)

      make_due
      go_idle
      idle.tick

      expect(fired).to eq([["tea"]])
    end
  end

  describe "a reminder turn that fails before injecting (cell B2)" do
    it "today: later ticks stay silent" do
      register
      make_due
      go_idle
      idle.tick
      expect(fired).to eq([["tea"]])

      engine.clear_due_reminder_names!
      allow(engine).to receive(:apply_staged_tools!).and_raise(RuntimeError, "boom")
      expect { engine.run_turn(session, nil, continue: true) }.to raise_error(RuntimeError, "boom")
      expect(engine.reminders_due?).to be(true)

      go_idle
      idle.tick

      expect(fired).to eq([["tea"]])
    end
  end
end
