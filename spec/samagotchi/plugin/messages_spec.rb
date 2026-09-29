# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/plugin/context"
require "support/thinking_off"

# ctx.messages (plan O1): no system prompt; mid-turn a worker's holds the
# turn so far (from its Bridge), the REPL's is the conversation before it.
RSpec.describe "ctx.messages" do
  include_context "thinking off"

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host))
  end
  let(:seen_mid_turn) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do |messages, **options|
      options[:on_stream_event].call({ type: :generation_chunk, iteration: 1, content: "Half an ans" })
      seen_mid_turn << [ctx.messages.map { |m| [m[:role], m[:content]] }, ctx.messages_partial?]
      Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [*messages, { role: "model", content: "ok" }],
                                         exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
  end

  it "leaves out the system prompt the REPL's conversation starts with" do
    session.messages = [{ role: "system", content: "the prompt" }, { role: "user", content: "hi" },
                        { role: "system", content: "a note", kind: "context_note" }]
    engine.session = session

    expect(ctx.messages.map { |m| m[:content] }).to eq(["hi", "a note"])
    expect(ctx.messages_partial?).to be(false)
  end

  it "is the conversation before a running turn without a Bridge (the REPL), and says so" do
    session.messages = [{ role: "system", content: "the prompt" }, { role: "user", content: "earlier" }]
    engine.session = session
    engine.run_turn(session, "now", on_event: ->(_e) {})

    expect(seen_mid_turn).to eq([[[["user", "earlier"]], true]])
  end

  it "adds the running turn so far with a Bridge (a worker)" do
    engine.session = session
    bridge = Samagotchi::Bridge.new(engine: engine, state_dir: Dir.mktmpdir, session_id: session.id)
    bridge.start
    begin
      engine.run_turn(session, "now", on_event: ->(_e) {})
    ensure
      bridge.stop
    end

    expect(seen_mid_turn).to eq([[[["user", "now"], ["model", "Half an ans"]], false]])
    # Between turns: the saved conversation, the turn once.
    expect(ctx.messages.map { |m| [m[:role], m[:content]] }).to eq([%w[user now], %w[model ok]])
  end

  describe "Bridge::TurnAccumulator.messages_of" do
    it "turns the prompt, text and merged lines into messages, in order, without tools" do
      turn = { prompt: "do it", images: [{ file: "images/a.png" }], parts: [
        { kind: "thinking", iteration: 1, text: "hm" },
        { kind: "text", iteration: 1, text: "Looking " },
        { kind: "tool", iteration: 1, tool: "read" },
        { kind: "text", iteration: 2, text: "now." },
        { kind: "input", iteration: 2, text: "also this" },
        { kind: "text", iteration: 3, text: "Sure." }
      ] }

      expect(Samagotchi::Bridge::TurnAccumulator.messages_of(turn)).to eq([
        { role: "user", content: "do it", images: [{ file: "images/a.png" }] },
        { role: "model", content: "Looking now." },
        { role: "user", content: "also this" },
        { role: "model", content: "Sure." }
      ])
    end

    it "has no prompt message for a continue turn" do
      expect(Samagotchi::Bridge::TurnAccumulator.messages_of({ prompt: nil, parts: [] })).to eq([])
    end
  end
end
