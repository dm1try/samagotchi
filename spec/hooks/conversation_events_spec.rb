# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/session"

# The read-only conversation copies the turn hooks get.
RSpec.describe "Conversation state on the turn hooks" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_thinking = ENV["THINKING_MODE"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["THINKING_MODE"] = "false"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    ENV["THINKING_MODE"] = original_thinking
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:history) { [{ role: "system", content: "sys" }, { role: "user", content: "old" }, { role: "model", content: "ok" }] }
  let(:stored) { history + [{ role: "user", content: "hi" }, { role: "model", content: "done" }] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    session.messages = history.map(&:dup)
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "done", conversation: stored.map(&:dup), exhausted: false,
                                         pending_tool_calls: false, tool_activity: [])
    )
  end

  it "before_turn sees the history before the turn, the prompt and the session id, frozen" do
    seen = nil
    engine.register_hook(:before_turn) { |e| seen = e }

    engine.run_turn(session, "hi")

    expect(seen).to include(type: :before_turn, prompt: "hi", session_id: session.id, messages: history)
    expect(seen[:messages]).to be_frozen
    expect(seen[:messages].first).not_to be(session.messages.first)
  end

  it "before_turn has no prompt on a continue" do
    session.last_prompt = "old"
    seen = nil
    engine.register_hook(:before_turn) { |e| seen = e }

    engine.run_turn(session, "ignored", continue: true)

    expect(seen).to include(prompt: nil, messages: history)
  end

  it "after_turn sees the conversation the turn stored and its status" do
    seen = nil
    engine.register_hook(:after_turn) { |e| seen = e }

    engine.run_turn(session, "hi")

    expect(seen).to include(type: :after_turn, status: "completed", messages: stored)
    expect(seen[:messages]).to be_frozen
  end

  it "after_turn says canceled for a cancelled turn" do
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "", conversation: stored.map(&:dup), exhausted: false,
                                         pending_tool_calls: false, tool_activity: [], canceled: true, cancellation_reason: :manual)
    )
    seen = nil
    engine.register_hook(:after_turn) { |e| seen = e }

    engine.run_turn(session, "hi")

    expect(seen).to include(status: "canceled")
    expect(seen[:messages].first(stored.length)).to eq(stored)
    expect(seen[:messages].last).to include(kind: "turn_note")
  end
end
