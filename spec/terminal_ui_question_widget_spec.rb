# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require "stringio"
require_relative "support/recording_surface"

# The REPL's ask_user_question widget, on the non-TTY path (plain gets/puts).
RSpec.describe Samagotchi::TerminalUI, "question widget" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:agent) { described_class.new(mode: :assist, client: client) }
  let(:engine) { agent.instance_variable_get(:@engine) }
  let(:pending) do
    { id: "q1", question: "Which one?", options: %w[Apple Banana Cherry], header: "Fruit",
      multi_select: false, allow_freeform: false }
  end

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  def answer_with(input, question = pending)
    out = StringIO.new
    old_stdin, old_stdout = $stdin, $stdout
    $stdin = StringIO.new(input)
    $stdout = out
    result = agent.send(:render_question_widget, question)
    [result, out.string]
  ensure
    $stdin, $stdout = old_stdin, old_stdout
  end

  it "shows the question and records a numbered choice" do
    allow(engine).to receive(:answer_question)

    result, out = answer_with("2\n")

    expect(result).to be(true)
    expect(out).to eq("Fruit\n? Which one?\n  1) Apple\n  2) Banana\n  3) Cherry\n" \
                      "  [Select one (e.g. 2); Enter alone cancels]\n? ? Which one? → Banana\n")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Banana"], freeform: nil)
  end

  it "re-asks after an invalid choice, a double pick or an unknown label" do
    allow(engine).to receive(:answer_question)

    _, out = answer_with("9\n1,2\nkiwi\nche\n")

    expect(out).to include("? 9\nInvalid choice '9': pick 1-3\n", "? kiwi\n", "This is single-select (pick one). Try again.\n",
                           "Unknown option 'kiwi'. Use numbers 1-3 or exact labels.\n")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Cherry"], freeform: nil)
  end

  it "takes several picks and freeform text when allowed" do
    allow(engine).to receive(:answer_question)

    _, out = answer_with("1 3; ripe ones\n", pending.merge(multi_select: true, allow_freeform: true))

    expect(out).to include("add '; text' for your own answer", "? Which one? → Apple, Cherry; ripe ones")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: %w[Apple Cherry], freeform: "ripe ones")
  end

  it "accepts unflagged freeform text with a note" do
    allow(engine).to receive(:answer_question)

    _, out = answer_with("1; extra\n")

    expect(out).to include("(note: freeform not flagged but accepting 'extra')\n")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Apple"], freeform: "extra")
  end

  # The choices wait in the notes slot; once answered they go, and one line
  # (the question and the answer) stays.
  it "shows the choices in the notes slot and commits one line once answered" do
    allow(engine).to receive(:answer_question)
    surface = RecordingSurface.new
    agent.instance_variable_set(:@surface, surface)

    answer_with("2\n")

    expect(surface.events).to eq([
      [:clear_slot, :activity],
      [:set_slot, :notes, ["Fruit", "? Which one?", "  1) Apple", "  2) Banana", "  3) Cherry",
                           "  [Select one (e.g. 2); Enter alone cancels]"]],
      [:set_slot, :editor, ["? "]],
      [:clear_slot, :notes],
      [:commit, "? Which one? → Banana"],
      [:clear_slot, :notes]
    ])
  end

  it "cancels the question on empty input or end of input" do
    allow(engine).to receive(:cancel_question)

    expect(answer_with("\n")).to eq([false, answer_with("").last])
    expect(answer_with("").last).to end_with("? Which one? → (cancelled)\n")
    expect(engine).to have_received(:cancel_question).with("user").exactly(3).times
  end

  # On a terminal the prompt stays open during turns (ReplInput): the
  # question turns it into the ? prompt and takes the lines submitted there.
  describe "asked while the prompt is open" do
    let(:answers) { Thread::Queue.new }
    let(:repl_input) do
      double("repl input", open?: true).tap do |input|
        allow(input).to receive(:ask) { |_prompt, &block| block.call(answers) }
      end
    end

    before { agent.instance_variable_set(:@repl_input, repl_input) }

    it "takes the next line submitted at the ? prompt as the answer" do
      allow(engine).to receive(:answer_question)
      answers << [:line, "2"]

      result, out = answer_with("")

      expect(result).to be(true)
      expect(repl_input).to have_received(:ask).with("? ")
      expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Banana"], freeform: nil)
      expect(out).to include("? Which one? → Banana")
    end

    it "asks again at the same prompt after an invalid answer" do
      allow(engine).to receive(:answer_question)
      answers << [:line, "banana split"] << [:line, "3"]

      _, out = answer_with("")

      expect(out).to include("Unknown option")
      expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Cherry"], freeform: nil)
    end

    it "cancels the question on Ctrl-D" do
      allow(engine).to receive(:cancel_question)
      answers << [:line, nil]

      expect(answer_with("").first).to be(false)
      expect(engine).to have_received(:cancel_question)
    end

    it "cancels the question when Ctrl-C cancels the turn" do
      allow(engine).to receive(:cancel_question)
      controller = Samagotchi::Client::CancellationController.new
      controller.cancel!(:ctrl_c)
      agent.instance_variable_set(:@active_cancel_controller, controller)

      result, out = answer_with("")

      expect(result).to be(false)
      expect(out).to end_with("? Which one? → (turn cancelled)\n")
      expect(engine).to have_received(:cancel_question)
    end
  end

  # Reline would commit the submitted "? 2" above the summary line.
  it "reads the answer at the ? prompt without echo, the main prompt with it" do
    echo = {}
    allow(Reline).to receive(:readline) { |prompt, _| echo[prompt] = !Thread.current[:samagotchi_reline_no_echo]; "2" }
    allow(agent).to receive(:read_prompt_line) { |prompt| echo[prompt] = !Thread.current[:samagotchi_reline_no_echo]; "hi" }

    agent.send(:read_repl_line, "? ", nil)
    agent.send(:read_repl_line, "> ", nil)

    expect(echo).to eq("? " => false, "> " => true)
  end

  # A continue offer's ? read has no echo either.
  it "shows an invalid continue answer above its error, the offer's choices staying" do
    surface = RecordingSurface.new
    agent.instance_variable_set(:@surface, surface)
    agent.instance_variable_set(:@continue_slot, true)
    invalid = Samagotchi::SessionCommands::Result.new(status: :error, output: "answer yes, no, or no, <reason>", changed: [],
                                                     model_name: "m", resume: false, shell: false)
    invalid.decision = :invalid
    agent.instance_variable_set(:@commands, double("commands", continue_answer: invalid))

    agent.send(:answer_continue_offer, nil, "/stats")

    expect(surface.lines).to eq(["? /stats", "\nmodel> answer yes, no, or no, <reason>"])
    expect(surface.events).not_to include([:clear_slot, :notes])
  end

  # A reminder turn drops a pending continue offer (the worker's rule), so a
  # later "no" can't roll the reminder's exchange back with the turn.
  it "drops a pending continue offer when a reminder turn runs, with one line" do
    surface = RecordingSurface.new
    agent.instance_variable_set(:@surface, surface)
    agent.instance_variable_set(:@continue_slot, true)
    flow = agent.instance_variable_get(:@turn_flow)
    flow.instance_variable_set(:@offer, { context: {}, no_interrupt: false })
    allow(engine).to receive_messages(due_reminder_names: ["stretch"], reminders_due?: true)
    allow(engine).to receive(:clear_due_reminder_names!)
    allow(agent).to receive(:run_engine_turn).and_return(nil)

    agent.send(:run_reminder_turn, nil)

    expect(flow.awaiting_continue?).to be(false)
    expect(surface.lines.first).to end_with("→ (dropped: a reminder ran)")
    expect(surface.events).to include([:clear_slot, :notes])
  end

  describe "an approval" do
    let(:approval) do
      { id: "a1", kind: "approval", header: "Approve tool call?",
        question: "execute: git push\n  in /r (repo r, branch main)\n  why: publishes (rule git-push, config)",
        options: ["Allow once", "Allow this call for the session", "Deny"],
        multi_select: false, allow_freeform: true, approval: { scopes: %w[once session] } }
    end

    it "shows the call, the options and how to answer, and takes y" do
      allow(engine).to receive(:answer_question)
      result, out = answer_with("y\n", approval)
      expect(result).to be(true)
      expect(out).to start_with("Approve tool call?\n! execute: git push\n  in /r (repo r, branch main)\n" \
                                "  why: publishes (rule git-push, config)\n  1) Allow once\n")
      expect(out).to include("Enter alone denies]\n", "! execute: git push → Allow once\n")
      expect(engine).to have_received(:answer_question).with(id: "a1", selected: ["Allow once"], freeform: nil)
    end

    it "takes n with a reason, and rejects a substring" do
      allow(engine).to receive(:answer_question)
      _, out = answer_with("allow\nn; too risky\n", approval)
      expect(out).to include("Answer with 1-3, y (Allow once) or n (Deny).")
      expect(engine).to have_received(:answer_question).with(id: "a1", selected: ["Deny"], freeform: "too risky")
      expect(out).to end_with("! execute: git push → Deny: too risky\n")
    end

    it "prints an edit's diff above the choices" do
      allow(engine).to receive(:answer_question)
      edit = approval.merge(question: "edit: /k.conf\n  why: outside (rule r, config)\n  change: +1 \u22121",
                            approval: { scopes: %w[once], preview: { "text" => "@@ -1 +1 @@\n-a\n+b", "added" => 1, "removed" => 1 } })
      _, out = answer_with("y\n", edit)
      expect(out).to start_with("@@ -1 +1 @@\n-a\n+b\nApprove tool call?\n! edit: /k.conf\n")
      expect(out).to include("  change: +1 \u22121\n")
    end

    it "denies on an empty line" do
      allow(engine).to receive(:cancel_question)
      result, out = answer_with("\n", approval)
      expect(result).to be(false)
      expect(out).to end_with("! execute: git push → (denied)\n")
      expect(engine).to have_received(:cancel_question)
    end
  end
end
