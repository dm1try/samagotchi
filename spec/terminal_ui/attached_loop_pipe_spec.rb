# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

# `chi -p X </dev/null`: the input ends at once, before the joining snapshot.
# The -p prompt still goes, once; the loop ends when its turn does, and says
# how it went (bin/chi's exit status). A failed prompt is not restored.
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "input from a pipe" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hello", wait_at_eof: true) }
  let(:events) { Queue.new }
  let(:posts) { [] }
  let(:origin) { { "client_id" => "tui:1", "enqueued_id" => "e1" } }

  before do
    allow(client).to receive(:follow) do |&block|
      events << block
      double("stream", close: nil)
    end
  end

  # The input has ended (nil) before the snapshot comes, as on a real run.
  def start(status: 202, body: nil)
    allow(client).to receive(:post_turn) do |**options|
      posts << options[:prompt]
      Samagotchi::BridgeClient::Response.new(status: status, body: body || %({"enqueued_id":"e#{posts.size}"}))
    end
    ended = Queue.new
    @thread = Thread.new { attached.run(input: ->(_prompt, _prefill) { (ended << true) && nil }) }
    @push = events.pop(timeout: 2)
    ended.pop(timeout: 2)
    @push.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
  end

  def result = @thread.join(2)&.value

  it "sends the -p prompt once and ends with :turn_failed when its turn fails" do
    start
    expect(@thread.join(0.3)).to be_nil # waiting for the turn
    @push.call("type" => "turn_started", "prompt" => "hello", "origin" => origin)
    @push.call("type" => "turn_failed", "summary" => "host main rejected the request: HTTP 400", "origin" => origin)
    @push.call("type" => "prompt_restored", "prompt" => "hello", "origin" => origin)

    expect(result).to eq(:turn_failed)
    expect(posts).to eq(["hello"])
    expect(screen.lines).not_to include("  prompt restored for retry")
  end

  # chi -p "/model x" </dev/null: the command, as if typed; the run waits
  # for its output, then ends.
  context "when the -p line is a session command" do
    let(:attached) do
      described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "/model fast", wait_at_eof: true)
    end

    it "runs it as the command and ends once it ran" do
      commands = []
      allow(client).to receive(:post_command) do |**options|
        commands << options[:line]
        Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}')
      end
      start
      expect(@thread.join(0.3)).to be_nil # waiting for its output
      @push.call("type" => "command_ran", "command_id" => "c1", "client_id" => "tui:1", "line" => "/model fast",
                 "status" => "ok", "output" => "switched to fast", "model_name" => "fast")

      expect(result).to eq(:detached)
      expect(commands).to eq(["/model fast"])
      expect(posts).to be_empty
      expect(screen.lines).to include("> /model fast", "model> switched to fast")
    end
  end

  it "ends with :detached once the turn completes" do
    start
    @push.call("type" => "turn_started", "prompt" => "hello", "origin" => origin)
    expect(@thread.join(0.3)).to be_nil
    @push.call("type" => "turn_completed", "turn_summary" => { "output" => "hi there", "tool_activity" => [] }, "origin" => origin)

    expect(result).to eq(:detached)
    expect(posts).to eq(["hello"])
    expect(screen.lines.last).to start_with("Detached; the session keeps running.")
  end

  # The after_turn hooks run after turn_completed (display_pending says
  # they will): their notices (source-links' sources:) come before the
  # answer_display that follows them, and the run waits for it.
  it "waits after its turn for the after_turn hooks' notices, then ends" do
    start
    @push.call("type" => "turn_started", "prompt" => "hello", "origin" => origin)
    @push.call("type" => "turn_completed", "turn_summary" => { "output" => "hi there", "tool_activity" => [] },
               "display_pending" => true, "origin" => origin)
    expect(@thread.join(0.3)).to be_nil
    @push.call("type" => "hook_notice", "hook" => "sources.rb (bundle source-links)", "text" => "sources: JIRA-1",
               "level" => "info", "between_turns" => true, "fallback_for" => "display")
    @push.call("type" => "answer_display", "display" => nil)

    expect(result).to eq(:detached)
    expect(screen.lines.last(2)).to eq(["source-links> sources: JIRA-1",
                                        "Detached; the session keeps running. Re-attach with: chi --attach s-1234"])
  end

  it "ends with :empty_answer when its turn ends with no answer" do
    start
    @push.call("type" => "turn_started", "prompt" => "hello", "origin" => origin)
    @push.call("type" => "turn_completed", "turn_summary" => { "output" => "", "tool_activity" => [], "empty_answer" => { "retries" => 1 } },
               "origin" => origin)

    expect(result).to eq(:empty_answer)
    expect(screen.lines).not_to include("")
    expect(screen.lines).to include("no answer: the model returned nothing (after 1 retry)")
  end

  it "ends with :unanswered when the turn asks a question nobody can answer" do
    start
    @push.call("type" => "turn_started", "prompt" => "hello", "origin" => origin)
    @push.call("type" => "question_requested", "pending_question" => { "id" => "q1", "question" => "Which?", "options" => [] })

    expect(result).to eq(:unanswered)
    expect(screen.lines.last).to eq("A question waits for an answer: chi --attach s-1234")
    # The launcher prints it in full (AttachLauncher.report_unanswered).
    expect(attached.unanswered).to include(id: "q1", question: "Which?")
  end

  # Queued behind another client's turn, then taken back (the web's ×):
  # no turn of its will come, so the run ends instead of waiting forever.
  it "ends with :turn_failed when its queued prompt is removed before it runs" do
    start(body: '{"enqueued_id":"e1","delivery":"queue"}')
    @push.call("type" => "turn_started", "prompt" => "other", "origin" => { "client_id" => "web:2", "enqueued_id" => "w1" })
    expect(@thread.join(0.3)).to be_nil
    @push.call("type" => "turn_dequeued", "enqueued_id" => "e1", "client_id" => "web:2")

    expect(result).to eq(:turn_failed)
    expect(screen.lines).to include("(your queued message was removed before it ran)")
  end

  it "ends :empty_answer (exit 1) with one notice when this terminal removes its own queued prompt" do
    start(body: '{"enqueued_id":"e1","delivery":"queue"}')
    @push.call("type" => "turn_started", "prompt" => "other", "origin" => { "client_id" => "web:2", "enqueued_id" => "w1" })
    expect(@thread.join(0.3)).to be_nil
    @push.call("type" => "turn_dequeued", "enqueued_id" => "e1", "client_id" => "tui:1")

    expect(result).to eq(:empty_answer)
    expect(screen.lines.count("(removed before it ran)")).to eq(1)
    expect(screen.lines).not_to include("(your queued message was removed before it ran)")
  end

  it "ends with :turn_failed when the worker refuses the prompt" do
    start(status: 409, body: '{"error":"busy"}')

    expect(result).to eq(:turn_failed)
    expect(posts).to eq(["hello"])
    expect(screen.lines).to include("could not send the prompt (409 busy)")
  end
end

# `printf '3\n' | chi --attach ID` on a session that already waits on a
# question: the pipe's lines are read at once, before the joining snapshot
# brings the question. They wait for the snapshot, so "3" answers it rather
# than going in as a new prompt.
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "piped answer to a pending question" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", wait_at_eof: true) }
  let(:events) { Queue.new }
  let(:answers) { [] }

  before do
    allow(client).to receive(:follow) do |&block|
      events << block
      double("stream", close: nil)
    end
    allow(client).to receive(:post_turn) { raise "the answer went in as a prompt" }
    allow(client).to receive(:answer) do |**options|
      answers << options
      Samagotchi::BridgeClient::Response.new(status: 200)
    end
  end

  it "answers the snapshot's question with a line read before the snapshot came" do
    lines = ["3", nil]
    read = Queue.new
    thread = Thread.new { attached.run(input: ->(_prompt, _prefill) { lines.shift.tap { read << true } }) }
    push = events.pop(timeout: 2)
    2.times { read.pop(timeout: 2) } # "3" and the end of the input, both before the snapshot
    turn = { "prompt" => "go", "origin" => nil, "parts" => [],
             "pending_question" => { "id" => "q1", "question" => "Which?", "options" => %w[a b c] } }
    push.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => turn, "queued" => [], "event_seq" => 1 })

    expect(thread.join(2)&.value).to eq(:detached)
    expect(answers).to eq([{ id: "q1", selected: ["c"], freeform: nil }])
  end
end
