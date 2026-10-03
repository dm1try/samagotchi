# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/continue_offer"
require "samagotchi/session_commands"
require "support/test_kernel"

# ContinueOffer's steer: the text a Continue answer came with joins the
# continue turn (N7), with its line breaks, and never a later turn.
RSpec.describe Samagotchi::ContinueOffer do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:offer) { { context: { original_prompt: "long task" }, no_interrupt: false } }
  let(:turn_flow) do
    instance_double(Samagotchi::TurnFlow, offer: offer, awaiting_continue?: true, after_turn: :continue_offered,
                                          before_continue_turn: nil)
  end
  let(:queued) { [] }
  # The worker's run_engine_turn, as far as the Engine: what it raises
  # before the turn begins (a save) comes out of it without a yield.
  let(:run_turn) do
    lambda do |prompt, **args, &block|
      raise(@fail_before_begin) if @fail_before_begin

      block.call(engine.run_turn(session, prompt, continue: args[:continue]), nil)
    end
  end
  let(:continue_offer) do
    described_class.new(engine: engine, turn_flow: turn_flow, run_turn: run_turn, max_iterations: ->(_) { 100 },
                        queue_command: ->(line, client_id:) { queued << [line, client_id] })
  end

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def kernel_result
    Samagotchi::LLM::ModelResult.new(text: "OK", conversation: [{ role: "model", content: "OK" }], exhausted: false,
                                     pending_tool_calls: false, tool_activity: [], canceled: false)
  end

  # Each turn's first boundary, as the kernel reads it.
  def drains
    @drains ||= [].tap do |seen|
      allow(kernel).to receive(:run) do |_messages, pending_input:, **|
        seen << pending_input.call(at_answer: false)
        kernel_result
      end
    end
  end

  # The offer asked, then answered as a UI (or chi answer) would.
  def answer(selected, freeform: nil)
    continue_offer.after_turn(kernel_result)
    engine.answer_question(id: engine.pending_question[:id], selected: selected, freeform: freeform, client_id: "web:2")
  end

  def resolved(resume:, decision:)
    Samagotchi::SessionCommands::Result.new(status: :ok, changed: [], resume: resume, decision: decision)
  end

  it "keeps the text's line breaks in the continue turn's steer; a Stop's line is one line" do
    drains
    answer(["Continue"], freeform: "line one\n  line two\n")
    expect(queued).to eq([["/continue yes", "web:2"]])

    continue_offer.run_continue_turn(client_id: "web:2")

    expect(drains).to eq([[{ text: "line one\n  line two", source: "user" }]])
    answer(["Stop"], freeform: "no more\nthanks")
    expect(queued.last).to eq(["/continue no, no more thanks", "web:2"])
  end

  it "drops the steer when the continue turn fails before it begins, so the next turn doesn't get it" do
    drains
    answer(["Continue"], freeform: "also X")
    @fail_before_begin = IOError.new("save failed")

    expect { continue_offer.run_continue_turn(client_id: "web:2") }.to raise_error(IOError)
    @fail_before_begin = nil
    engine.run_turn(session, "something else")

    expect(drains).to eq([[]])
  end

  it "drops the steer when a /continue that ran first answered the offer without a turn" do
    drains
    answer(["Continue"], freeform: "also X")
    # A typed /continue no got to the queue first; the answer's /continue
    # yes then finds nothing to continue.
    continue_offer.after_command(resolved(resume: false, decision: :abort), resolved: true)
    continue_offer.after_command(resolved(resume: false, decision: nil), resolved: false)
    # A later offer, answered with a typed /continue yes.
    continue_offer.run_continue_turn(client_id: "tui:1")

    expect(drains).to eq([[]])
  end

  it "keeps the steer across a command that didn't answer the offer" do
    drains
    answer(["Continue"], freeform: "also X")
    continue_offer.after_command(resolved(resume: false, decision: nil), resolved: false)
    continue_offer.run_continue_turn(client_id: "web:2")

    expect(drains).to eq([[{ text: "also X", source: "user" }]])
  end
end
