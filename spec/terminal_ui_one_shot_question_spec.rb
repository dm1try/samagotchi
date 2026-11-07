# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require "stringio"
require "timeout"

# chi -p … --non-interactive has no one to ask: the model's question is
# dismissed at once, never read from stdin. A pipe whose writer stays open
# (a parent holding chi's stdin) would block that read forever.
RSpec.describe Samagotchi::TerminalUI, "a question in the one-shot turn" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:agent) { described_class.new(client: client, prompt: "hi") }
  let(:engine) { agent.engine }

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  it "dismisses the question without reading stdin, even from a pipe left open" do
    reader, writer = IO.pipe
    old_stdin = $stdin
    old_stdout = $stdout
    old_stderr = $stderr
    $stdin = reader
    $stdout = StringIO.new
    $stderr = StringIO.new
    events = []
    engine.subscribe(observer: ->(e) { events << e if e[:type] == :question_cancelled })
    result = Timeout.timeout(5) do # timeout-ok: a hang guard: with no terminal the question returns at once
      engine.request_question(question: "Which one?", options: %w[Apple Banana], header: "Fruit")
    end

    # No one could answer: the model isn't told the user dismissed it.
    note = JSON.parse(result)["note"]
    expect(JSON.parse(result)).to include("dismissed" => true, "note" => Samagotchi::QuestionDesk::UNANSWERABLE_NOTE)
    expect(note).to include("non-interactive")
    expect(note).not_to include("user dismissed")
    expect(events.map { |e| e[:reason] }).to eq(["non_interactive"])
    expect(engine.pending_question).to be_nil
    # stdout keeps the answer alone; the question's line goes to stderr.
    expect($stdout.string).to eq("")
    expect($stderr.string).to include("? Which one? → (dismissed: no one to answer in a non-interactive run)")
  ensure
    $stdin = old_stdin
    $stdout = old_stdout
    $stderr = old_stderr
    writer&.close
    reader&.close
  end
end
