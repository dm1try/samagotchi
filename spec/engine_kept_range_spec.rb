# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/turn_note"
require "support/test_kernel"

# The end event names the turn's own messages in what it kept:
# kept[kept_from...kept_to] (Engine#end_turn; Bridge::TurnDrawings reads
# it). Measured under the system head the turn added, before its reminders
# and prompt, so a head-less session, a fork and a tail rewrite all land on
# the turn's own messages. No message gains a key.
RSpec.describe Samagotchi::Engine, "the end event's kept range" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:events) { [] }
  let(:end_types) { %i[turn_completed turn_canceled turn_failed] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    engine.subscribe(observer: ->(event) { events << event })
  end

  def answer_with(*added, **result)
    allow(kernel).to receive(:run) do |messages, **|
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + added, exhausted: false,
                                       pending_tool_calls: false, tool_activity: [], canceled: false, **result)
    end
  end

  def end_event = events.find { |e| end_types.include?(e[:type]) }

  def own_messages
    event = end_event
    session.messages[event[:kept_from]...event[:kept_to]]
  end

  def roles(messages) = messages.map { |m| m[:role] }

  it "starts after the system head a head-less session's first turn gains" do
    answer_with({ role: "model", content: "ok" })

    engine.run_turn(session, "hi")

    expect(end_event).to include(kept_from: 1, kept_to: 3)
    expect(own_messages).to match([a_hash_including(role: "user", content: "hi"), a_hash_including(role: "model", content: "ok")])
    expect(session.messages.first[:role]).to eq("system")
  end

  it "starts after a fork's history under the head it gains (an opener note stays outside)" do
    opener = Samagotchi::ContextNote.message(note_id: "n1", text: "from the parent", source: "continue",
                                             created_at: "2026-11-08T07:00:00Z")
    session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "before" }, opener]
    answer_with({ role: "model", content: "ok" })

    engine.run_turn(session, "hi")

    expect(end_event).to include(kept_from: 4, kept_to: 6)
    expect(roles(own_messages)).to eq(%w[user model])
  end

  it "keeps the range on the event only: no message gains a key" do
    session.messages = [{ role: "system", content: "old head" }, { role: "user", content: "earlier" }]
    answer_with({ role: "model", content: "ok" })

    engine.run_turn(session, "hi")

    expect(end_event).to include(kept_from: 2, kept_to: 4)
    expect(session.messages.flat_map(&:keys).uniq).not_to include(:kept_from, :kept_to)
  end

  it "takes in a reminder that went into the turn" do
    engine.reminder_store.register({ name: "tea", description: "brew", interval_minutes: 1 })
    store = engine.reminder_store
    store.instance_variable_get(:@mutex).synchronize do
      store.reminders["tea"][:next_fire_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    end
    session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "before" }]
    answer_with({ role: "model", content: "ok" })

    engine.run_turn(session, "hi")

    expect(roles(own_messages)).to eq(%w[system user model])
    expect(own_messages.first[:content]).to start_with("[SYSTEM: REMINDERS DUE")
  end

  it "covers an empty answer whose spent retry nudge went (TurnNote.without_trailing_nudge)" do
    nudge = Samagotchi::TurnNote.empty_retry
    answer_with({ role: "model", content: "" }, nudge, text: "")

    engine.run_turn(session, "hi")

    expect(own_messages.map { |m| m[:role] }).to eq(%w[user model system])
    expect(Samagotchi::TurnNote.note?(own_messages.last)).to be(true)
    expect(own_messages.none? { |m| Samagotchi::TurnNote.retry_nudge?(m) }).to be(true)
  end

  it "covers a canceled turn's steps and its note" do
    answer_with({ role: "model", content: "half" }, canceled: true, cancellation_reason: :user)

    engine.run_turn(session, "hi")

    expect(end_event[:type]).to eq(:turn_canceled)
    expect(roles(own_messages)).to eq(%w[user model system])
  end

  it "covers a failed turn's kept steps and its note" do
    allow(kernel).to receive(:run) do |messages, **|
      partial = messages + [{ role: "model", content: "step" }, { role: "tool_response", content: "out" }]
      raise Samagotchi::LLM::FailedTurn.attach(RuntimeError.new("boom"), partial)
    end

    expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError, "boom")

    expect(end_event[:type]).to eq(:turn_failed)
    expect(roles(own_messages)).to eq(%w[user model tool_response system])
  end

  it "gives a Continue stopped before its first step, whose note replaces the last one, no range of its own" do
    session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "before" },
                        Samagotchi::TurnNote.cancelled(:user, seconds: 1)]
    allow(kernel).to receive(:run) { raise Interrupt }

    expect { engine.run_turn(session, nil, continue: true) }.to raise_error(Interrupt)

    expect(end_event).to include(type: :turn_canceled, kept_from: 4, kept_to: 4)
  end

  it "names no range when the turn kept nothing (stopped before the model)" do
    allow(engine).to receive(:prepare_turn).and_return(false)

    engine.run_turn(session, "hi")

    expect(end_event[:type]).to eq(:turn_canceled)
    expect(end_event).not_to include(:kept_from, :kept_to)
  end
end
