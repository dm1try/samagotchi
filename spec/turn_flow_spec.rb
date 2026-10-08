# frozen_string_literal: true

require "samagotchi/turn_flow"
require "samagotchi/kernel_loop"

RSpec.describe Samagotchi::TurnFlow do
  # Engine's out-of-turn messages API over a plain array.
  let(:engine_class) do
    Class.new do
      attr_accessor :messages

      def initialize(messages) = @messages = messages
      def messages_checkpoint = @messages.map(&:dup)
      def rollback_to(checkpoint) = @messages = checkpoint.map(&:dup)
      def append_messages(extra) = @messages += extra.map(&:dup)
    end
  end
  let(:before) { [{ role: "system", content: "sys" }, { role: "user", content: "old" }, { role: "model", content: "ok" }] }
  let(:engine) { engine_class.new(before.map(&:dup)) }
  let(:flow) { described_class.new(engine: engine) }

  def result(conversation, canceled: false, exhausted: false, pending: false, activity: [])
    Samagotchi::LLM::ModelResult.new(text: "", conversation: conversation, exhausted: exhausted,
                                     pending_tool_calls: pending, tool_activity: activity, canceled: canceled,
                                     cancellation_reason: canceled ? :ctrl_c : nil)
  end

  # What a prompt turn leaves in the engine (Engine#run_turn replaces the
  # session's messages with the kernel's conversation).
  def run_prompt(text, tail)
    flow.before_prompt_turn
    engine.messages = engine.messages + [{ role: "user", content: text }] + tail
  end

  describe "#after_turn" do
    it "completes a turn and forgets the checkpoint" do
      run_prompt("go", [{ role: "model", content: "done" }])

      expect(flow.after_turn(result(engine.messages))).to eq(:completed)
      expect(flow.rollback!).to be(false)
      expect(flow.awaiting_continue?).to be(false)
    end

    it "offers to continue an exhausted turn, with a summary of it, and keeps the checkpoint" do
      activity = [{ tool: "execute", status: "ok", params: 'command="ls"' }]
      run_prompt("list it", [{ role: "model", content: "calling ls" }, { role: "tool_response", content: "a b" }])

      outcome = flow.after_turn(result(engine.messages, exhausted: true, pending: true, activity: activity), no_interrupt: true)

      expect(outcome).to eq(:continue_offered)
      expect(flow.awaiting_continue?).to be(true)
      expect(flow.offer[:context]).to eq(original_prompt: "list it", tool_trace: ['execute status=ok params=command="ls"'],
                                         last_model_intent: "calling ls")
      expect(flow.offer[:no_interrupt]).to be(true)
      expect(flow.rollback!).to be(true)
      expect(engine.messages).to eq(before)
    end

    it "keeps a cancelled turn's partial progress and the checkpoint for !rollback" do
      run_prompt("go", [{ role: "model", content: "Partial\n[interrupted]" }])

      expect(flow.after_turn(result(engine.messages, canceled: true))).to eq(:cancelled)
      expect(engine.messages.last[:content]).to eq("Partial\n[interrupted]")
      expect(flow.rollback!).to be(true)
      expect(engine.messages).to eq(before)
    end

    it "rolls a cancelled continue back to where it started and keeps the offer" do
      run_prompt("go", [{ role: "tool_response", content: "r1" }])
      flow.after_turn(result(engine.messages, exhausted: true, pending: true))
      offered = engine.messages_checkpoint

      flow.before_continue_turn
      engine.messages = engine.messages + [{ role: "tool_response", content: "r2" }]
      expect(flow.after_turn(result(engine.messages, canceled: true), continue: true)).to eq(:continue_cancelled)

      expect(engine.messages).to eq(offered)
      expect(flow.awaiting_continue?).to be(true)
    end

    it "summarizes the first turn of an empty session (a worker's) too" do
      engine.messages = []
      run_prompt("list it", [{ role: "model", content: "calling ls" }, { role: "tool_response", content: "a b" }])

      flow.after_turn(result(engine.messages, exhausted: true, pending: true))

      expect(flow.offer[:context]).to include(original_prompt: "list it", last_model_intent: "calling ls")
    end

    # The kernel sends (and returns) earlier model messages without their
    # thinking, so after the first turn the returned conversation never
    # starts with the saved checkpoint verbatim.
    it "summarizes a turn after one whose model message kept its thinking" do
      engine.messages = [{ role: "system", content: "sys" }, { role: "user", content: "one" },
                         { role: "model", content: "<think>first</think>\n\nONE" }]
      flow.before_prompt_turn
      returned = [{ role: "system", content: "sys" }, { role: "user", content: "one" }, { role: "model", content: "\nONE" },
                  { role: "user", content: "list it" }, { role: "model", content: "calling ls" }]

      flow.after_turn(result(returned, exhausted: true, pending: true))

      expect(flow.offer[:context]).to include(original_prompt: "list it", last_model_intent: "calling ls")
    end

    it "summarizes a continue that runs out again against the original prompt" do
      run_prompt("the task", [{ role: "tool_response", content: "r1" }])
      flow.after_turn(result(engine.messages, exhausted: true, pending: true))

      flow.before_continue_turn
      engine.messages = engine.messages + [{ role: "model", content: "still going" }]
      expect(flow.after_turn(result(engine.messages, exhausted: true, pending: true), continue: true)).to eq(:continue_offered)

      expect(flow.offer[:context][:original_prompt]).to eq("the task")
      expect(flow.offer[:context][:last_model_intent]).to eq("still going")
    end

    it "keeps the model's thinking and tool-call markup out of last_model_intent" do
      tool_call = "<tool_call>\n<function=execute>\n<parameter=command>\nls\n</parameter>\n</function>\n</tool_call>"
      run_prompt("list it", [{ role: "model", content: "<think>\nI should list.\n</think>\n\nListing now.\n#{tool_call}" }])

      flow.after_turn(result(engine.messages, exhausted: true, pending: true))

      expect(flow.offer[:context][:last_model_intent]).to eq("Listing now.")
    end

    it "falls back to the thinking text when the model wrote nothing else" do
      run_prompt("list it", [{ role: "model", content: "<think>\nI should list.\n</think>\n<tool_call>\n<function=execute>\n</function>\n</tool_call>" }])

      flow.after_turn(result(engine.messages, exhausted: true, pending: true))

      expect(flow.offer[:context][:last_model_intent]).to eq("I should list.")
    end
  end

  describe "#prompt_turn_failed" do
    # A provider error the Engine marked: the turn's work stayed in the
    # session (kept_steps), or nothing past the prompt did (nil).
    def failure(summary = "HTTP 500", kept_steps: nil)
      error = Samagotchi::LLM::ServerError.new("main: #{summary}", host: "main", status: 500)
      Samagotchi::LLM::FailedTurn.attach(error, nil).tap { |e| e.kept_steps = kept_steps }
    end

    def restored_note(error) = Samagotchi::TurnNote.failed(error.summary, restored: true)

    it "restores the pre-turn conversation and drops the checkpoint" do
      run_prompt("go", [])

      expect(flow.prompt_turn_failed).to eq(:restored)

      expect(engine.messages).to eq(before)
      expect(flow.rollback!).to be(false)
      expect(flow.awaiting_continue?).to be(false)
    end

    it "leaves the failure note after the restored conversation, in one rollback" do
      run_prompt("go", [])
      error = failure
      allow(engine).to receive(:rollback_to).and_call_original

      expect(flow.prompt_turn_failed(error: error)).to eq(:restored)

      expect(engine.messages).to eq(before + [restored_note(error)])
      expect(engine).to have_received(:rollback_to).once
    end

    it "replaces the note a previous failure left" do
      flow.prompt_turn_failed(error: failure("HTTP 500"))
      run_prompt("again", [])
      second = failure("HTTP 503")

      flow.prompt_turn_failed(error: second)

      expect(engine.messages).to eq(before + [restored_note(second)])
    end

    it "leaves the note even with no checkpoint" do
      error = failure

      flow.prompt_turn_failed(error: error)

      expect(engine.messages).to eq(before + [restored_note(error)])
    end

    it "leaves no note when told not to (an image that never reached the model)" do
      run_prompt("go", [])

      flow.prompt_turn_failed(error: failure, note: false)

      expect(engine.messages).to eq(before)
    end

    it "words a wake turn's note for what woke it, with what becomes of its news" do
      run_prompt("go", [])
      error = failure

      flow.prompt_turn_failed(error: error, wake: "a delegate's report", wake_kept: "chi keeps the report.")

      expect(engine.messages.last).to eq(Samagotchi::TurnNote.failed(error.summary, wake: "a delegate's report",
                                                                                    kept: "chi keeps the report."))
    end

    describe "after a turn that got somewhere (the Engine kept its steps)" do
      let(:kept_note) { Samagotchi::TurnNote.failed("server error from host main: main: HTTP 500", steps: 2) }
      let(:steps) do
        [{ role: "model", content: "calling" }, { role: "tool_response", content: "r1" },
         { role: "model", content: "calling" }, { role: "tool_response", content: "r2" }, kept_note]
      end

      it "keeps the turn as the Engine left it, and the checkpoint for !rollback" do
        run_prompt("go", steps)
        kept = engine.messages.map(&:dup)
        allow(engine).to receive(:rollback_to).and_call_original

        expect(flow.prompt_turn_failed(error: failure(kept_steps: 2))).to eq(:kept)

        expect(engine.messages).to eq(kept)
        expect(engine).not_to have_received(:rollback_to)
        expect(flow.awaiting_continue?).to be(false)
        expect(flow.rollback!).to be(true)
        expect(engine.messages).to eq(before)
      end

      it "rolls a context overflow back and restores its prompt all the same (kept, it would stay over the window)" do
        run_prompt("go", steps)
        overflow = Samagotchi::LLM::BadRequest.new("main: HTTP 400: too long", host: "main", status: 400, context_overflow: true)
        error = Samagotchi::LLM::FailedTurn.attach(overflow, nil).tap { |e| e.kept_steps = 2 }

        expect(flow.prompt_turn_failed(error: error)).to eq(:restored)

        expect(engine.messages).to eq(before + [restored_note(error)])
        expect(flow.rollback!).to be(false)
      end

      it "words a wake turn's note for what woke it, without the news the rollback would keep" do
        run_prompt("go", steps)
        error = failure(kept_steps: 2)

        flow.prompt_turn_failed(error: error, wake: "a delegate's report", wake_kept: "chi keeps the report.")

        expect(engine.messages.first(before.length + 5)).to eq(before + [{ role: "user", content: "go" }] + steps.first(4))
        expect(engine.messages.last).to eq(Samagotchi::TurnNote.failed(error.summary, wake: "a delegate's report", steps: 2))
        expect(engine.messages.last[:content]).not_to include("chi keeps the report")
      end
    end
  end

  # A worker settles a turn's delegate reports by it (Worker#run_engine_turn).
  describe "#restores" do
    it "counts each return to a checkpoint: a failed turn that got nowhere, a canceled continue turn, !rollback" do
      expect(flow.restores).to eq(0)
      run_prompt("go", [])
      flow.prompt_turn_failed
      expect(flow.restores).to eq(1)

      flow.before_continue_turn
      flow.after_turn(result(nil, canceled: true), continue: true)
      expect(flow.restores).to eq(2)

      run_prompt("again", [{ role: "model", content: "partial" }])
      flow.after_turn(result(engine.messages, canceled: true))
      flow.rollback!
      expect(flow.restores).to eq(3)
    end

    it "stays when a failed turn's work stays, or a turn is kept" do
      run_prompt("go", [{ role: "tool_response", content: "r1" }])
      error = Samagotchi::LLM::FailedTurn.attach(Samagotchi::LLM::ServerError.new("main: HTTP 500", host: "main", status: 500), nil)
      error.kept_steps = 1
      flow.prompt_turn_failed(error: error)
      run_prompt("then", [{ role: "model", content: "done" }])
      flow.after_turn(result(engine.messages))

      expect(flow.restores).to eq(0)
    end
  end

  describe "#abort_continue!" do
    before do
      run_prompt("the task", [{ role: "model", content: "working" }, { role: "tool_response", content: "r1" }])
      flow.after_turn(result(engine.messages, exhausted: true, pending: true))
    end

    it "keeps the interrupted turn with a note for the model (D3); !rollback still erases it" do
      kept = engine.messages.dup
      flow.abort_continue!

      expect(engine.messages).to eq(kept + [Samagotchi::TurnNote.not_continued])
      expect(flow.awaiting_continue?).to be(false)
      expect(flow.rollback!).to be(true)
      expect(engine.messages).to eq(before)
    end

    it "notes the reason with a summary of the interrupted turn" do
      kept = engine.messages.dup
      flow.abort_continue!(reason: "too slow")

      expect(engine.messages[0...-1]).to eq(kept)
      note = engine.messages.last
      expect(note[:role]).to eq("user")
      expect(note[:content]).to start_with("I chose not to continue the turn that ran out of steps because: too slow")
      expect(note[:content]).to include("- original_prompt: the task", "- interrupted_tools: (none)", "- last_model_intent: working")
      expect(flow.awaiting_continue?).to be(false)
    end
  end

  describe ".continue_decision" do
    {
      "" => [:resume, nil], "yes" => [:resume, nil], "Y" => [:resume, nil], "/continue" => [:resume, nil],
      "no" => [:abort, nil], "n" => [:abort, nil], "no, too slow" => [:abort_with_reason, "too slow"],
      "N: wrong file" => [:abort_with_reason, "wrong file"], "maybe" => [:invalid, nil]
    }.each do |answer, decision|
      it "reads #{answer.inspect} as #{decision.first}" do
        expect(described_class.continue_decision(answer)).to eq(decision)
      end
    end
  end

  it "drops the offer and keeps the partial turn when a new prompt comes instead of an answer" do
    run_prompt("go", [{ role: "tool_response", content: "r1" }])
    flow.after_turn(result(engine.messages, exhausted: true, pending: true))
    partial = engine.messages_checkpoint

    flow.drop_offer!

    expect(flow.awaiting_continue?).to be(false)
    expect(engine.messages).to eq(partial)
  end

  it "drops a pending offer on !rollback: the offered turn is gone" do
    run_prompt("go", [{ role: "tool_response", content: "r1" }])
    flow.after_turn(result(engine.messages, exhausted: true, pending: true))

    expect(flow.rollback!).to be(true)

    expect(engine.messages).to eq(before)
    expect(flow.awaiting_continue?).to be(false)
  end

  it "forgets the checkpoint once the conversation changed outside a turn" do
    run_prompt("go", [{ role: "model", content: "Partial" }])
    flow.after_turn(result(engine.messages, canceled: true))

    flow.note_conversation_changed

    expect(flow.rollback!).to be(false)
  end

  it "drops a pending continue offer when a reminder turn runs, and closes the rollback window after it" do
    run_prompt("go", [{ role: "tool_response", content: "r1" }])
    flow.after_turn(result(engine.messages, exhausted: true, pending: true))
    expect(flow.before_reminder_turn).to be(true)
    expect(flow.awaiting_continue?).to be(false)
    engine.messages = engine.messages + [{ role: "model", content: "stretch!" }]
    flow.after_reminder_turn
    expect(flow.rollback!).to be(false)
    expect(engine.messages.last[:content]).to eq("stretch!")

    run_prompt("go", [{ role: "model", content: "Partial" }])
    flow.after_turn(result(engine.messages, canceled: true))
    expect(flow.before_reminder_turn).to be(false)
    flow.after_reminder_turn
    expect(flow.rollback!).to be(false)
  end

  # D11: a note absorbed after the checkpoint (between turns) survives
  # every restore of it.
  describe "context notes" do
    let(:note) { { role: "system", kind: "note", note_id: "n1", content: "[CONTEXT NOTE from cli]\nx\n[END NOTE]" } }

    def absorb_note = engine.append_messages([note])

    it "keeps a note on !rollback after a cancelled turn" do
      run_prompt("go", [{ role: "model", content: "Partial\n[interrupted]" }])
      flow.after_turn(result(engine.messages, canceled: true))
      absorb_note

      expect(flow.rollback!).to be(true)
      expect(engine.messages).to eq(before + [note])
    end

    it "keeps a note when a continue offer is answered no" do
      run_prompt("list it", [{ role: "model", content: "calling ls" }])
      flow.after_turn(result(engine.messages, exhausted: true, pending: true))
      absorb_note

      flow.abort_continue!(reason: "too slow")

      # The turn stays (D3), the note with it.
      expect(engine.messages).to include(note)
      expect(engine.messages.map { |m| m[:content] }).to include("list it", "calling ls")
      expect(engine.messages.last[:role]).to eq("user")
    end

    it "doesn't duplicate a note the checkpoint already holds" do
      absorb_note
      run_prompt("go", [{ role: "model", content: "Partial\n[interrupted]" }])
      flow.after_turn(result(engine.messages, canceled: true))

      flow.rollback!

      expect(engine.messages).to eq(before + [note])
    end
  end
end
