# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/continue_offer"
require "samagotchi/queued_command"
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
                                          before_continue_turn: nil, resume_from: 7)
  end
  let(:queued) { [] }
  # The worker's run_engine_turn, as far as the Engine: what fails before
  # the turn begins (its save) is yielded as the error, with no result.
  let(:run_turn) do
    lambda do |prompt, **args, &block|
      next block.call(nil, @fail_before_begin) if @fail_before_begin

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
    engine.answer_question(id: engine.pending_question.id, selected: selected, freeform: freeform, client_id: "web:2")
  end

  def resolved(resume:, decision:)
    Samagotchi::SessionCommands::Result.new(status: :ok, changed: [], resume: resume, decision: decision)
  end

  def command_from(client_id) = Samagotchi::QueuedCommand.new(command_id: "c1", client_id: client_id, line: "/continue")

  it "keeps the text's line breaks in the continue turn's steer; a Stop's line is one line" do
    drains
    answer(["Continue"], freeform: "line one\n  line two\n")
    expect(queued).to eq([["/continue yes", "web:2"]])

    continue_offer.run_continue_turn(command_from("web:2"))

    expect(drains).to eq([[{ text: "line one\n  line two", source: "user" }]])
    answer(["Stop"], freeform: "no more\nthanks")
    expect(queued.last).to eq(["/continue no, no more thanks", "web:2"])
  end

  it "drops the steer when the continue turn fails before it begins, so the next turn doesn't get it" do
    drains
    answer(["Continue"], freeform: "also X")
    @fail_before_begin = IOError.new("save failed")

    continue_offer.run_continue_turn(command_from("web:2"))
    expect(engine.pending_question).to have_attributes(kind: "continue", effects: %w[spend deny])
    @fail_before_begin = nil
    engine.run_turn(session, "something else")

    expect(drains).to eq([[]])
  end

  it "asks again when its own step before the turn fails, and drops the steer" do
    drains
    answer(["Continue"], freeform: "also X")
    allow(turn_flow).to receive(:before_continue_turn).and_raise(IOError, "checkpoint")

    expect { continue_offer.run_continue_turn(command_from("web:2")) }.not_to raise_error
    expect(engine.pending_question).to have_attributes(kind: "continue")
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
    continue_offer.run_continue_turn(command_from("tui:1"))

    expect(drains).to eq([[]])
  end

  it "keeps the steer across a command that didn't answer the offer" do
    drains
    answer(["Continue"], freeform: "also X")
    continue_offer.after_command(resolved(resume: false, decision: nil), resolved: false)
    continue_offer.run_continue_turn(command_from("web:2"))

    expect(drains).to eq([[{ text: "also X", source: "user" }]])
  end

  it "resumes the run the offer's turn started (TurnFlow#resume_from), so the Continue keeps its reasoning" do
    args = nil
    offer = described_class.new(engine: engine, turn_flow: turn_flow, run_turn: ->(_prompt, **a) { args = a },
                                max_iterations: ->(_) { 100 })

    offer.run_continue_turn(command_from("web:2"))

    expect(args).to include(continue: true, resumed: true, resume_from: 7, max_iterations: 100)
  end

  describe "the offer turn's enqueued_id" do
    let(:args) { {} }
    let(:recording) do
      described_class.new(engine: engine, turn_flow: turn_flow, run_turn: ->(_prompt, **a) { args.merge!(a) },
                          max_iterations: ->(_) { 100 })
    end

    before { engine.session = session }

    it "goes on the continue turn's origin, so its last_turn and reply are that turn's" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, limit: 100, enqueued_id: "q1",
                                                   ended_at: "2026-10-13T10:00:00.000Z")

      recording.run_continue_turn(command_from("cli:answer"))

      expect(args[:origin]).to eq(Samagotchi::TurnOrigin.new(client_id: "cli:answer", enqueued_id: "q1"))
    end

    it "keeps a participant's author: their turn continues as theirs, inside the review boundary" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, limit: 100, enqueued_id: "q1",
                                                   author: "p:p_0123abcd")

      recording.run_continue_turn(command_from("web:owner"))

      expect(args[:origin]).to eq(Samagotchi::TurnOrigin.new(client_id: "web:owner", enqueued_id: "q1", author: "p:p_0123abcd"))
    end

    it "doesn't continue a participant's turn they may no longer run (revoked, at the cap)" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, limit: 100, enqueued_id: "q1",
                                                   author: "p:p_0123abcd")
      refusing = described_class.new(engine: engine, turn_flow: turn_flow, run_turn: ->(_prompt, **a) { args.merge!(a) },
                                     max_iterations: ->(_) { 100 },
                                     participant_refused: ->(author) { "revoked" if author == "p:p_0123abcd" })
      allow(turn_flow).to receive(:abort_continue!)

      refusing.run_continue_turn(command_from("web:owner"))

      expect(args).to eq({})
      expect(turn_flow).to have_received(:abort_continue!)
    end

    # The worker's run_command, on a real TurnFlow: the owner's Continue on
    # the offer of a participant refused since clears the offer (no resume
    # announced, no question left, awaiting_continue? false: idle exit,
    # /exit and the participant's held turns go on) and ends a wait on the
    # offer turn (not_continued).
    it "clears the offer when the owner continues a participant's turn refused since" do
      real_flow = Samagotchi::TurnFlow.new(engine: engine)
      real_flow.instance_variable_set(:@offer, { context: { original_prompt: "x" }, no_interrupt: false })
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, limit: 100, enqueued_id: "q1",
                                                   author: "p:p_0123abcd")
      announced = []
      allow(engine).to receive(:announce).and_wrap_original do |original, event|
        announced << event
        original.call(event)
      end
      refusing = described_class.new(engine: engine, turn_flow: real_flow, run_turn: ->(_prompt, **a) { args.merge!(a) },
                                     max_iterations: ->(_) { 100 }, participant_refused: ->(_) { "revoked" })
      refusing.send(:ask)
      expect(engine.pending_question).not_to be_nil

      # Worker#run_command's order.
      awaiting = refusing.awaiting?
      result = resolved(resume: true, decision: :resume)
      refusing.announce_resolved(result, command_from("web:owner")) if refusing.resolved?(awaiting, result)
      refusing.after_command(result, resolved: true)
      refusing.run_continue_turn(command_from("web:owner"))

      expect(args).to eq({})
      expect({ awaiting: refusing.awaiting?, question: engine.pending_question }).to eq(awaiting: false, question: nil)
      expect(session.last_turn).to have_attributes(outcome: "not_continued", enqueued_id: "q1")
      expect(announced.select { |e| e[:type] == :continue_resolved }.map { |e| e[:decision] }).to eq(["refused"])
      expect(announced.find { |e| e[:type] == :hook_notice }).to include(hook: "participants", level: :warn)
    end

    it "leaves the origin as the client's alone when the offer turn ran no input (or an older last_turn)" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, limit: 100)

      recording.run_continue_turn(command_from("web:2"))

      expect(args[:origin]).to eq(Samagotchi::TurnOrigin.new(client_id: "web:2"))
    end

    it "goes on a Stop's not_continued last_turn, so a wait on that turn ends" do
      session.last_turn = Samagotchi::LastTurn.new(outcome: "completed", exhausted: true, enqueued_id: "q1",
                                                   ended_at: "2026-10-13T10:00:00.000Z")

      recording.announce_resolved(resolved(resume: false, decision: :stop), command_from("cli:answer"))

      expect(session.last_turn).to have_attributes(outcome: "not_continued", enqueued_id: "q1")
      expect(session.last_turn.ended_at).not_to eq("2026-10-13T10:00:00.000Z")
    end
  end
end
