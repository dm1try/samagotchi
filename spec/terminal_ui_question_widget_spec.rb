# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require "stringio"

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

  it "cancels the question on empty input or end of input" do
    allow(engine).to receive(:cancel_question)

    expect(answer_with("\n").first).to be(false)
    expect(answer_with("").first).to be(false)
    expect(engine).to have_received(:cancel_question).with("user").twice
  end
end
