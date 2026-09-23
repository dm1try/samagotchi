# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }

  def feed(*events)
    events.map { |e| attached.handle_event(JSON.parse(JSON.generate(e))) }
  end

  def snapshot(messages: [], current_turn: nil, queued: [], type: :snapshot)
    { type: type, snapshot: { messages: messages, current_turn: current_turn, queued: queued, event_seq: 9 },
      session_state_snapshot: { status: current_turn ? "running" : "idle", message_count: messages.size } }
  end

  def summary(output, tool_activity: [])
    { tool_activity: tool_activity, output: output, resumable: false }
  end

  describe "joining" do
    it "shows the session and its last exchange" do
      feed(snapshot(messages: [{ role: "system", content: "sys" }, { role: "user", content: "hi" },
                               { role: "model", content: "hello there" }]))

      expect(screen.lines).to eq(["Attached to session s-1234 (2 messages). Ctrl-D detaches; the session keeps running.",
                                  "user> hi", "hello there"])
      expect(attached).not_to be_running
    end

    it "shows queued prompts and the turn so far, with a tool still running as the status line" do
      turn = { prompt: "check the logs", origin: { client_id: "web:tab1", enqueued_id: "e1" }, continue: false,
               parts: [{ kind: "text", iteration: 1, text: "Looking" },
                       { kind: "tool", iteration: 1, call_index: 0, tool: "read", params: "path=log", status: "ok" },
                       { kind: "input", iteration: 2, text: "also errors", origins: [] },
                       { kind: "tool", iteration: 2, call_index: 0, tool: "grep", params: nil, status: "running" }],
               pending_question: nil, event_seq: 9 }
      feed(snapshot(current_turn: turn, queued: [{ enqueued_id: "e2", client_id: "web:tab2", prompt: "next one" }]))

      expect(screen.lines.drop(1)).to eq(["web> check the logs", "tool> read path=log: ok", "input> also errors",
                                          "queued web> next one"])
      expect(screen.statuses.last).to eq("| running grep…")
      expect(attached).to be_running
    end

    it "does not repeat the joined turn's earlier tools in its summary" do
      activity = { action: "reading file", tool: "read", params: "path=log", status: "ok" }
      turn = { prompt: "go", origin: nil, parts: [{ kind: "tool", tool: "read", params: "path=log", status: "ok" }] }
      feed(snapshot(current_turn: turn), { type: :turn_completed, turn_summary: summary("done", tool_activity: [activity]) })

      expect(screen.lines.drop(1)).to eq(["user> go", "tool> read path=log: ok", "done"])
      expect(attached).not_to be_running
    end

    it "shows only the end of an answer made of long lines" do
      feed(snapshot(messages: [{ role: "user", content: "essay" }, { role: "model", content: "#{"x" * 2000}END" }]))

      expect(screen.lines.last).to start_with("(… earlier text)\n…x").and end_with("xEND")
      expect(screen.lines.last.length).to be < 1250
    end

    it "shows only the end of a long last answer" do
      answer = (1..30).map { |i| "line #{i}" }.join("\n")
      feed(snapshot(messages: [{ role: "user", content: "essay" }, { role: "model", content: answer }]))

      expect(screen.lines.last).to eq("(… 18 earlier lines)\n#{(19..30).map { |i| "line #{i}" }.join("\n")}")
    end

    it "marks a resync after a reset frame" do
      feed(snapshot, snapshot(type: :reset))

      expect(screen.lines.last).to eq("(resynced with the session)")
    end
  end

  describe "prompts from other clients" do
    before { feed(snapshot) }

    it "shows another client's queued prompt once, not again when its turn starts" do
      feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "web:tab1", prompt: "from the web" },
           { type: :turn_started, prompt: "from the web", origin: { client_id: "web:tab1", enqueued_id: "e1" } })

      expect(screen.lines.drop(1)).to eq(["web> from the web"])
    end

    it "skips its own prompts, which the prompt line already shows" do
      feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "tui:1", prompt: "mine" },
           { type: :turn_started, prompt: "mine", origin: { client_id: "tui:1", enqueued_id: "e1" } })

      expect(screen.lines.drop(1)).to be_empty
    end

    it "shows a turn that was never announced (reminders, initial prompt)" do
      feed({ type: :turn_started, prompt: "[SYSTEM: reminders due]", origin: { client_id: "system:reminder", enqueued_id: "r1" } },
           { type: :turn_started, prompt: "first", origin: nil })

      expect(screen.lines.drop(1)).to eq(["reminder> [SYSTEM: reminders due]", "user> first"])
    end

    it "notes input merged into the running turn" do
      feed({ type: :input_merged, count: 2, origins: [{ client_id: "web:a" }, { client_id: "tui:1" }] })

      expect(screen.lines.last).to eq("(2 messages merged into the running turn)")
    end
  end

  describe "turn endings" do
    before { feed(snapshot, { type: :turn_started, prompt: "p", origin: { client_id: "tui:1" } }, { type: :generation_started, iteration: 1 }) }

    it "says a turn was cancelled and clears the status line" do
      feed({ type: :turn_canceled, cancellation_reason: :ctrl_c })

      expect(screen.lines.last).to eq("turn cancelled (ctrl_c)")
      expect(screen.statuses.last).to be_nil
      expect(attached).not_to be_running
    end

    it "shows a failed turn's error" do
      feed({ type: :turn_failed, error_class: "Samagotchi::Client::RetryExhausted", message: "server down" })

      expect(screen.lines.last).to eq("turn failed: server down (Samagotchi::Client::RetryExhausted)")
      expect(attached).not_to be_running
    end

    it "shows a provider error's one-line summary" do
      feed({ type: :turn_failed, error_class: "Samagotchi::LLM::AuthError", message: "fw: set FW_KEY",
             error_kind: :auth, retryable: false, host: "fw", summary: "auth failed for host fw: set FW_KEY" })

      expect(screen.lines.last).to eq("turn failed: auth failed for host fw: set FW_KEY")
    end
  end

  it "keeps the latest recap for /recap, from the join's snapshot or announced later, until a turn starts" do
    joined = snapshot
    joined[:snapshot][:recap] = "earlier recap"
    feed(joined)
    expect(attached.recap).to eq("earlier recap")

    feed({ type: :recap_ready, recap: "we fixed the bug", generation: 3 })
    expect(attached.recap).to eq("we fixed the bug")
    expect(screen.lines.size).to eq(1)

    feed({ type: :turn_started, prompt: "next", origin: { client_id: "web:1" } })
    expect(attached.recap).to be_nil
  end

  it "ends on stream_closed, saying why" do
    results = feed(snapshot, { type: "stream_closed", reason: "unreachable" })

    expect(results.last).to eq(:closed)
    expect(screen.lines.last).to eq("Lost the session's worker (unreachable). Resume it with: chi --shared --resume s-1234")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "#run" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:stream) { double("stream", close: nil) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:ack) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1"}') }

  def snapshot(current_turn: nil)
    { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => current_turn, "queued" => [], "event_seq" => 1 } }
  end

  # Joins with +first+, then reads +inputs+ in order (an :interrupt entry is a
  # Ctrl-C); nil or running out of inputs is Ctrl-D.
  def run_with(inputs, first: snapshot)
    allow(client).to receive(:follow) do |&block|
      block.call(first)
      stream
    end
    attached.run(input: ->(_prompt) { (entry = inputs.shift) == :interrupt ? raise(Interrupt) : entry })
  end

  it "ends as closed when the worker goes away" do
    expect(run_with([], first: { "type" => "stream_closed", "reason" => "unreachable" })).to eq(:closed)
  end

  it "sends what the user types, with its client id, and detaches on Ctrl-D" do
    allow(client).to receive(:post_turn).and_return(ack)

    expect(run_with(["hello", "  ", nil])).to eq(:detached)

    expect(client).to have_received(:post_turn).once.with(prompt: "hello", client_id: "tui:1")
    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --attach s-1234")
    expect(stream).to have_received(:close)
  end

  it "sends a first prompt (chi -p) once it has joined, shown as the user's own line" do
    allow(client).to receive(:post_turn).and_return(ack)
    loop_with_prompt = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hello")
    allow(client).to receive(:follow) do |&block|
      block.call(snapshot)
      block.call(snapshot.merge("type" => "reset"))
      stream
    end

    expect(loop_with_prompt.run(input: ->(_prompt) {})).to eq(:detached)

    expect(client).to have_received(:post_turn).once.with(prompt: "hello", client_id: "tui:1")
    expect(screen.lines[0..1]).to eq(["Attached to session s-1234 (0 messages). Ctrl-D detaches; the session keeps running.",
                                      "> hello"])
  end

  it "says so when the worker does not take the prompt" do
    allow(client).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"owned_by_tui"}'))

    run_with(["hello"])

    expect(screen.lines).to include("could not send the prompt (409 owned_by_tui)")
  end

  it "shows /stats from the worker's live metrics" do
    metrics = { turns: 2, tool_calls_total: 1, tool_errors: 0, tool_calls_by_tool: { read: 1 }, iterations_total: 3,
                tokens_in: 10, tokens_out: 5, tokens_total: 15, token_source: :server, gen_latency_ms: 120,
                cancellations: 0, retries: 0 }
    allow(client).to receive(:get_json).with("state")
      .and_return(JSON.parse(JSON.generate(session_state_snapshot: { metrics: metrics })))

    run_with(["/stats"])

    expect(screen.lines).to include(a_string_including("turns:            2"),
                                    a_string_including("tokens in/out:    10/5 (total 15, server-reported)"))
  end

  it "says when there is no recap yet" do
    run_with(["/recap"])

    expect(screen.lines).to include("no recap yet: one comes after a quiet stretch, when recap: is configured")
  end

  it "declines the commands that need the local Engine" do
    run_with(["/model x", "/models", "/continue", "!rollback", "!ls"])

    expect(screen.lines.count { |l| l.end_with?("not available in attached mode yet (`chi --no-shared` runs a plain REPL)") }).to eq(5)
  end

  it "cancels the running turn on Ctrl-C, and only then" do
    allow(client).to receive(:cancel).and_return(Samagotchi::BridgeClient::Response.new(status: 202))

    run_with([:interrupt], first: snapshot(current_turn: { "prompt" => "p", "parts" => [] }))
    expect(client).to have_received(:cancel).once.with(reason: "ctrl_c")

    idle = described_class.new(client: client, screen: screen, client_id: "tui:1")
    allow(client).to receive(:follow) { |&b| b.call(snapshot) && stream }
    idle.run(input: ->(_p) { (@idle_inputs ||= [:interrupt, nil]).shift.then { |e| e == :interrupt ? raise(Interrupt) : e } })
    expect(client).to have_received(:cancel).once
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "questions" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:question) { { "id" => "q1", "question" => "Which one?", "options" => %w[Apple Banana Cherry] } }
  let(:typed) { Queue.new }
  let(:prompts) { [] }

  def snapshot(pending_question: nil)
    turn = { "prompt" => "p", "parts" => [], "pending_question" => pending_question }
    { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => turn, "queued" => [], "event_seq" => 1 } }
  end

  # Runs the loop on a thread. The fake terminal blocks in each read, like
  # Reline, until the spec types a line; events are pushed with #push.
  def start(first: snapshot)
    allow(client).to receive(:follow) do |&block|
      @push = block
      block.call(first)
      double("stream", close: nil)
    end
    @thread = Thread.new { attached.run(input: ->(prompt) { prompts << prompt; typed.pop }) }
    wait_for { prompts.any? }
  end

  def push(event) = @push.call(event)

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    expect(yield).to be_truthy
  end

  def finish
    typed << nil
    @thread.join(2)
  end

  it "asks a question at the choice prompt and sends the answer" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    push("type" => "question_requested", "pending_question" => question)

    wait_for { prompts.last == "choice> " }
    expect(screen.lines.last).to include("? Which one?", "  2) Banana")
    typed << "2"
    wait_for { prompts.last == "> " }
    finish

    # The question stays in the output, above the answer typed at choice>.
    expect(screen.slots).not_to have_key(:notes)
    expect(client).to have_received(:answer).with(id: "q1", selected: ["Banana"], freeform: nil)
  end

  it "re-asks after an invalid answer, and closes when another UI answers first" do
    start
    push("type" => "question_requested", "pending_question" => question)
    wait_for { prompts.last == "choice> " }

    typed << "9"
    wait_for { screen.lines.include?("Invalid choice '9': pick 1-3") }
    push("type" => "question_answered", "id" => "q1", "answer" => { "selected" => ["Apple"], "freeform" => nil })
    wait_for { prompts.last == "> " }
    finish

    expect(screen.lines).to include("(answered in another UI: Apple)")
  end

  it "says so when its answer came too late" do
    allow(client).to receive(:answer)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"question_not_pending"}'))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "choice> " }

    typed << "1"
    wait_for { prompts.last == "> " }
    finish

    expect(screen.lines).to include(a_string_including("? Which one?"))
    expect(screen.lines).to include("(already answered in another UI)")
  end

  it "dismisses the question on an empty answer, as the REPL does" do
    allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "choice> " }

    typed << "  "
    wait_for { prompts.last == "> " }
    # Every UI gets the cancel, this one too: it is already closed here.
    push("type" => "question_cancelled", "id" => "q1", "reason" => "dismissed")
    finish

    expect(client).to have_received(:dismiss_question).with(id: "q1")
    expect(screen.lines).to include("(cancelled)")
    expect(screen.lines).not_to include("(question cancelled)")
  end

  it "closes the question when it was answered or cancelled before the dismiss" do
    allow(client).to receive(:dismiss_question)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"question_not_pending"}'))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "choice> " }

    typed << ""
    wait_for { prompts.last == "> " }
    finish

    expect(screen.lines).to include("(question already closed in another UI)")
  end

  it "keeps the question open when the worker can't dismiss it" do
    allow(client).to receive(:dismiss_question)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: '{"error":"not_found"}'))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "choice> " }

    typed << ""
    wait_for { screen.lines.last.to_s.start_with?("could not dismiss") }
    finish

    expect(screen.lines).to include("could not dismiss the question (404 not_found); Ctrl-C cancels the turn")
    expect(prompts.last).to eq("choice> ")
  end
end
