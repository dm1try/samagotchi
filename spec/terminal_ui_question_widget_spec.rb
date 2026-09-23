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
    expect(out).to eq("Fruit\n? Which one?\n  1) Apple\n  2) Banana\n  3) Cherry\n  Enter empty to cancel.\nchoice> ")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Banana"], freeform: nil)
  end

  it "re-asks after an invalid choice, a double pick or an unknown label" do
    allow(engine).to receive(:answer_question)

    _, out = answer_with("9\n1,2\nkiwi\nche\n")

    expect(out).to include("Invalid choice '9': pick 1-3\n", "This is single-select (pick one). Try again.\n",
                           "Unknown option 'kiwi'. Use numbers 1-3 or exact labels.\n")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Cherry"], freeform: nil)
  end

  it "takes several picks and freeform text when allowed" do
    allow(engine).to receive(:answer_question)

    _, out = answer_with("1 3; ripe ones\n", pending.merge(multi_select: true, allow_freeform: true))

    expect(out).not_to include("Enter empty to cancel.")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: %w[Apple Cherry], freeform: "ripe ones")
  end

  it "accepts unflagged freeform text with a note" do
    allow(engine).to receive(:answer_question)

    _, out = answer_with("1; extra\n")

    expect(out).to include("(note: freeform not flagged but accepting 'extra')\n")
    expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Apple"], freeform: "extra")
  end

  # Committed, not in the notes slot: on a live region a slot's rows vanish
  # when it is cleared, and the question must stay above its answer.
  it "commits the question as output before it reads the answer" do
    allow(engine).to receive(:answer_question)
    surface = RecordingSurface.new
    agent.instance_variable_set(:@surface, surface)

    answer_with("2\n")

    expect(surface.events).to eq([
      [:clear_slot, :activity],
      [:commit, "Fruit\n? Which one?\n  1) Apple\n  2) Banana\n  3) Cherry\n  Enter empty to cancel."],
      [:set_slot, :editor, ["choice> "]]
    ])
  end

  it "cancels the question on empty input or end of input" do
    allow(engine).to receive(:cancel_question)

    expect(answer_with("\n").first).to be(false)
    expect(answer_with("").first).to be(false)
    expect(engine).to have_received(:cancel_question).with("user").twice
  end

  # Ctrl-C at choice>: RelineSeam asks the interrupt handler; declining
  # makes Reline end the read with Interrupt.
  it "cancels the turn and the question on Ctrl-C at choice>" do
    allow(engine).to receive(:cancel_question)
    controller = Samagotchi::Client::CancellationController.new
    agent.instance_variable_set(:@active_cancel_controller, controller)
    allow(Samagotchi::TerminalUI::RelineSeam).to receive(:supported?).and_return(true)
    allow(Reline).to receive(:readline) do
      taken = Samagotchi::TerminalUI::RelineSeam.interrupt_handler.call
      raise Interrupt unless taken
    end
    tty_in = StringIO.new
    tty_out = StringIO.new
    [tty_in, tty_out].each { |io| io.define_singleton_method(:tty?) { true } }
    old_stdin, old_stdout = $stdin, $stdout
    $stdin, $stdout = tty_in, tty_out
    result = agent.send(:render_question_widget, pending)
    $stdin, $stdout = old_stdin, old_stdout

    expect(result).to be(false)
    expect(controller).to be_cancelled
    expect(engine).to have_received(:cancel_question)
  ensure
    $stdin, $stdout = old_stdin, old_stdout if old_stdin
  end

  # A reminder turn runs with the prompt open (its read on @prompt_reader);
  # Reline reads one line at a time, so there is no choice> read then.
  describe "asked while the prompt is open" do
    it "takes the next line submitted there as the answer" do
      allow(engine).to receive(:answer_question)
      agent.instance_variable_set(:@prompt_reader, Thread.new { "2" })

      result, out = answer_with("")

      expect(result).to be(true)
      expect(engine).to have_received(:answer_question).with(id: "q1", selected: ["Banana"], freeform: nil)
      expect(out).to include("  Answer at the prompt.\n")
      expect(out).not_to include("choice> ")
      expect(agent.instance_variable_get(:@prompt_reader)).to be_nil
    end

    it "cancels the question and keeps the prompt when Ctrl-C cancels the turn" do
      allow(engine).to receive(:cancel_question)
      line = Queue.new
      reader = Thread.new { line.pop }
      agent.instance_variable_set(:@prompt_reader, reader)
      controller = Samagotchi::Client::CancellationController.new
      controller.cancel!(:ctrl_c)
      agent.instance_variable_set(:@active_cancel_controller, controller)

      result, out = answer_with("")

      expect(result).to be(false)
      expect(out).not_to include("choice> ")
      expect(engine).to have_received(:cancel_question)
      expect(agent.instance_variable_get(:@prompt_reader)).to be(reader)
    ensure
      line << nil
    end
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
      expect(out).to include("  Enter empty to deny.\n")
      expect(engine).to have_received(:answer_question).with(id: "a1", selected: ["Allow once"], freeform: nil)
    end

    it "takes n with a reason, and rejects a substring" do
      allow(engine).to receive(:answer_question)
      _, out = answer_with("allow\nn; too risky\n", approval)
      expect(out).to include("Answer with 1-3, y (Allow once) or n (Deny).")
      expect(engine).to have_received(:answer_question).with(id: "a1", selected: ["Deny"], freeform: "too risky")
    end

    it "denies on an empty line" do
      allow(engine).to receive(:cancel_question)
      result, = answer_with("\n", approval)
      expect(result).to be(false)
      expect(engine).to have_received(:cancel_question)
    end

    it "puts a line from the open prompt that isn't an answer back into the prompt, and asks at choice>" do
      allow(engine).to receive(:answer_question)
      agent.instance_variable_set(:@prompt_reader, Thread.new { "what does this do?" })
      _, out = answer_with("2\n", approval)
      expect(out).to include("(not an answer; your line is back in the prompt)", "choice> ")
      expect(agent.instance_variable_get(:@next_input_prefill)).to eq("what does this do?")
      expect(engine).to have_received(:answer_question).with(id: "a1", selected: ["Allow this call for the session"],
                                                             freeform: nil)
    end
  end
end
