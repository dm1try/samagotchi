# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/plugin/context"
require "support/thinking_off"

# ctx.steer, ctx.stop_turn and ctx.stop_generation (docs/plugins.md,
# Context): a plugin's command or thread acting on the running turn.
RSpec.describe "ctx.steer, ctx.stop_turn and ctx.stop_generation" do
  include_context "thinking off"

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:engine) { Samagotchi::Engine.new(client: client) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "check-in", label: "plugin.rb (bundle check-in)", settings: {},
                                    host: engine.send(:plugin_host))
  end

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  it "ctx.steer is false with no turn, and queues into a running one (source: the bundle)" do
    expect(ctx.steer("nobody home")).to be(false)
    queued = nil
    replies = [%(<|tool_call>call:execute{command: "true"}<tool_call|>), "done"]
    allow(client).to receive(:complete) do
      queued = ctx.steer("status?") if queued.nil?
      replies.shift || "done"
    end

    engine.run_turn(session, "go")

    expect(queued).to be(true)
    expect(session.messages).to include(role: "user", kind: "steer", source: "check-in", content: "status?")
  end

  it "ctx.stop_turn cancels the running turn once, with a notice, and is false with no turn" do
    expect(ctx.stop_turn("nothing to stop")).to be(false)
    results = []
    allow(client).to receive(:complete) do |_prompt, **kwargs|
      ctrl = kwargs[:cancel_controller]
      raise Samagotchi::Client::RequestCancelled.new(ctrl.reason) if ctrl&.cancelled?

      2.times { results << ctx.stop_turn("stopped from check-in") }
      %(<|tool_call>call:execute{command: "true"}<tool_call|>)
    end
    events = []

    engine.run_turn(session, "go", on_event: ->(e) { events << e })

    expect(results).to eq([true, false])
    expect(events.find { |e| e[:type] == :hook_notice })
      .to include(hook: "plugin.rb (bundle check-in)", text: "stopped the turn: stopped from check-in", level: :warn)
    expect(events.last).to include(type: :turn_canceled, cancellation_reason: :hook)
  end

  it "ctx.stop_generation cuts the streaming generation once, silently, and the turn asks again (by: the bundle)" do
    expect(ctx.stop_generation("nothing streams")).to be(false)
    results = []
    calls = 0
    allow(client).to receive(:complete) do |_prompt, **kwargs|
      calls += 1
      next "done" if calls > 1

      2.times { results << ctx.stop_generation("its thinking kept repeating itself") }
      ctrl = kwargs[:cancel_controller]
      raise Samagotchi::Client::RequestCancelled.new(ctrl.reason) if ctrl&.cancelled?

      "never"
    end
    events = []

    result = engine.run_turn(session, "go", on_event: ->(e) { events << e })

    expect(results).to eq([true, false])
    expect(result.output).to eq("done")
    expect(events.none? { |e| e[:type] == :hook_notice }).to be(true)
    expect(events.find { |e| e[:type] == :empty_answer_retry }).to include(stopped_by: "check-in")
    expect(session.messages).to include(Samagotchi::TurnNote.cut_retry("check-in", "its thinking kept repeating itself"))
  end
end
