# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:log) { instance_double(Samagotchi::DebugLog, write: nil) }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", log: log) }

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

      expect(screen.lines).to eq(["user> hi", "hello there"])
      expect(log).to have_received(:write).with("[attached] joined session s-1234 (2 messages)")
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

      expect(screen.lines).to eq(["web> check the logs", "tool> read path=log: ok", "input> also errors",
                                          "queued web> next one"])
      expect(screen.statuses.last).to eq("| running grep…")
      expect(attached).to be_running
    end

    it "does not repeat the joined turn's earlier tools in its summary" do
      activity = { action: "reading file", tool: "read", params: "path=log", status: "ok" }
      turn = { prompt: "go", origin: nil, parts: [{ kind: "tool", tool: "read", params: "path=log", status: "ok" }] }
      feed(snapshot(current_turn: turn), { type: :turn_completed, turn_summary: summary("done", tool_activity: [activity]) })

      expect(screen.lines).to eq(["user> go", "tool> read path=log: ok", "done"])
      expect(attached).not_to be_running
    end

    it "leaves the last answer's thinking and tool-call markup out, keeping its layout" do
      answer = "<think>\nplan it\n</think>\n\nHere:\n```\ndef a\n    b = 1\nend\n```"
      feed(snapshot(messages: [{ role: "user", content: "code" }, { role: "model", content: answer }]))

      expect(screen.lines).to eq(["user> code", "Here:\n```\ndef a\n    b = 1\nend\n```"])
    end

    it "shows the last model message with text when the latest is only a tool call" do
      feed(snapshot(messages: [{ role: "user", content: "go" }, { role: "model", content: "<think>a</think>Looking." },
                               { role: "tool_response", content: "r" },
                               { role: "model", content: "<think>b</think>\n<tool_call>\n<function=read>\n</function>\n</tool_call>" }]))

      expect(screen.lines).to eq(["user> go", "Looking."])
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

      expect(screen.lines).to eq(["web> from the web"])
    end

    it "skips its own prompts, which the prompt line already shows" do
      feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "tui:1", prompt: "mine" },
           { type: :turn_started, prompt: "mine", origin: { client_id: "tui:1", enqueued_id: "e1" } })

      expect(screen.lines).to be_empty
    end

    it "shows a turn that was never announced (reminders, initial prompt)" do
      feed({ type: :turn_started, prompt: "[SYSTEM: reminders due]", origin: { client_id: "system:reminder", enqueued_id: "r1" } },
           { type: :turn_started, prompt: "first", origin: nil })

      expect(screen.lines).to eq(["reminder> [SYSTEM: reminders due]", "user> first"])
    end

    it "notes input merged into the running turn, after the answer it follows" do
      feed({ type: :input_merged, count: 2, origins: [{ client_id: "web:a" }, { client_id: "tui:1" }] })
      expect(screen.lines).to be_empty

      feed({ type: :pending_input_merged, iteration: 2, count: 2, content: "a\n\nb", answer: "the essay" })

      expect(screen.lines.last(2)).to eq(["the essay", "(2 messages merged into the running turn)"])
    end
  end

  describe "turn endings" do
    before { feed(snapshot, { type: :turn_started, prompt: "p", origin: { client_id: "tui:1" } }, { type: :generation_started, iteration: 1 }) }

    it "says a turn was cancelled and clears the status line" do
      feed({ type: :turn_canceled, cancellation_reason: :ctrl_c })

      expect(screen.lines.last(2)).to eq(["turn cancelled (ctrl_c)", described_class::ROLLBACK_HINT])
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
    expect(screen.lines).to be_empty

    feed({ type: :turn_started, prompt: "next", origin: { client_id: "web:1" } })
    expect(attached.recap).to be_nil
  end

  it "shows the guardrail load warning a snapshot carries when joining" do
    joined = snapshot
    joined[:snapshot][:guardrail_warning] = "hook g.rb (config) failed to load (LoadError: x)"
    feed(joined)

    expect(screen.lines).to include("guardrails> hook g.rb (config) failed to load (LoadError: x)")
  end

  it "shows a guardrail load warning" do
    feed({ type: :guardrail_warning, message: "hook g.rb (config) failed to load (LoadError: x)" })
    expect(screen.lines.last).to eq("guardrails> hook g.rb (config) failed to load (LoadError: x)")
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
    attached.run(input: ->(_prompt, _prefill) { (entry = inputs.shift) == :interrupt ? raise(Interrupt) : entry })
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

    expect(loop_with_prompt.run(input: ->(_prompt, _prefill) {})).to eq(:detached)

    expect(client).to have_received(:post_turn).once.with(prompt: "hello", client_id: "tui:1")
    expect(screen.lines[0]).to eq("> hello")
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
    allow(client).to receive(:get_json).with("stats")
      .and_return(JSON.parse(JSON.generate(metrics: metrics.merge(context_window_tokens: 128_000, context_window_source: :server))))

    run_with(["/stats"])

    expect(screen.lines).to include(a_string_including("turns:            2"),
                                    a_string_including("tokens in/out:    10/5 (total 15, server-reported)"),
                                    a_string_including("context window:   128000 tokens (server)"))
  end

  it "reads /stats from /state on a worker without the stats route" do
    allow(client).to receive(:get_json).with("stats").and_return(nil)
    allow(client).to receive(:get_json).with("state")
      .and_return(JSON.parse(JSON.generate(session_state_snapshot: { metrics: { turns: 4 } })))

    run_with(["/stats"])

    expect(screen.lines).to include(a_string_including("turns:            4"))
  end

  describe "/recap, with the REPL's words" do
    def state(**fields) = JSON.parse(JSON.generate(session_state_snapshot: fields))

    it "says how to turn recap on when it's off" do
      allow(client).to receive(:get_json).with("state").and_return(state(recap_enabled: false))

      run_with(["/recap"])

      expect(screen.lines).to include(a_string_starting_with("recap feature not enabled (add recap: {host_ref:, model:} to config.yml"))
    end

    it "says when one would come, while there is none yet" do
      allow(client).to receive(:get_json).with("state")
        .and_return(state(recap_enabled: true, recap_min_user_turns: 2, recap_inactivity_seconds: 300))

      run_with(["/recap"])

      expect(screen.lines).to include("no recap available yet — the session needs at least 2 user turns and 300s " \
                                      "of inactivity to generate one automatically")
    end

    it "shows the latest recap" do
      allow(client).to receive(:get_json).with("state").and_return(state(recap_enabled: true))
      joined = snapshot
      joined["snapshot"]["recap"] = "We fixed the bug."

      run_with(["/recap"], first: joined)

      expect(screen.lines).to include("session recap:\nWe fixed the bug.")
    end

    it "says so when the worker doesn't answer" do
      allow(client).to receive(:get_json).with("state").and_return(nil)

      run_with(["/recap"])

      expect(screen.lines).to include("(no recap settings: the worker did not answer)")
    end
  end

  it "sends session commands to the worker, which runs them" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))

    run_with(["/model x", "/models", "/continue", "!rollback", "!ls"])

    %w[/model\ x /models /continue !rollback !ls].each do |line|
      expect(client).to have_received(:post_command).with(line: line.delete("\\"), client_id: "tui:1")
    end
    expect(screen.lines.grep(/not available/)).to be_empty
  end

  it "says so when the worker is older than the command route" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: '{"error":"not_found"}'))

    run_with(["/model x"])

    expect(screen.lines).to include("this session's worker runs an older chi and can't run commands; " \
                                    "restart it: chi sessions stop s-1234 && chi --resume s-1234 (its turns still work)")
  end

  it "cancels the running turn on Ctrl-C, and only then" do
    allow(client).to receive(:cancel).and_return(Samagotchi::BridgeClient::Response.new(status: 202))

    run_with([:interrupt], first: snapshot(current_turn: { "prompt" => "p", "parts" => [] }))
    expect(client).to have_received(:cancel).once.with(reason: "ctrl_c")

    idle = described_class.new(client: client, screen: screen, client_id: "tui:1")
    allow(client).to receive(:follow) { |&b| b.call(snapshot) && stream }
    idle.run(input: ->(_p, _prefill) { (@idle_inputs ||= [:interrupt, nil]).shift.then { |e| e == :interrupt ? raise(Interrupt) : e } })
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
  let(:prefills) { [] }

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
    @thread = Thread.new do
      attached.run(input: lambda { |prompt, prefill|
        prompts << prompt
        prefills << prefill
        typed.pop
      })
    end
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

  it "asks a question at the ? prompt, its choices in the notes slot, and sends the answer" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    push("type" => "question_requested", "pending_question" => question)

    wait_for { prompts.last == "? " }
    wait_for { screen.slots[:notes] }
    expect(screen.slots[:notes]).to include("? Which one?", "  2) Banana")
    typed << "2"
    wait_for { prompts.last == "> " }
    finish

    # The choices go; one line stays: the question and the answer.
    expect(screen.slots).not_to have_key(:notes)
    expect(screen.lines).to include("? Which one? → Banana")
    expect(screen.lines.join("\n")).not_to include("2) Banana")
    expect(client).to have_received(:answer).with(id: "q1", selected: ["Banana"], freeform: nil)
  end

it "puts what was typed at the prompt aside for the question and back after it" do
  allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
  allow_any_instance_of(Samagotchi::TerminalUI::LineReader).to receive(:typed_text).and_return("half typed")
  start
  push("type" => "question_requested", "pending_question" => question)

  wait_for { prompts.last == "? " }
  expect(prefills.last).to be_nil
  typed << "2"
  wait_for { prompts.last == "> " }
  finish

  expect(prefills.last).to eq("half typed")
end

  describe "an approval" do
    let(:approval) do
      { "id" => "a1", "kind" => "approval", "header" => "Approve tool call?",
        "question" => "execute: git push\n  in /r (repo r, branch main)\n  why: pushes (rule git-push, config)",
        "options" => ["Allow once", "Allow this call in this repo", "Deny"], "allow_freeform" => true,
        "approval" => { "scopes" => %w[once repo] } }
    end

    it "shows the call and takes y (also when it was pending before the attach)" do
      allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      start(first: snapshot(pending_question: approval))
      wait_for { prompts.last == "? " }
      wait_for { screen.slots[:notes] }
      expect(screen.slots[:notes]).to include("Approve tool call?", "! execute: git push", "  why: pushes (rule git-push, config)",
                                              "  3) Deny")
      typed << "y"
      wait_for { prompts.last == "> " }
      finish
      expect(client).to have_received(:answer).with(id: "a1", selected: ["Allow once"], freeform: nil)
      expect(screen.lines).to include("! execute: git push → Allow once")
    end

    it "sends n with a reason, and says denied on an empty answer" do
      allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      start
      push("type" => "question_requested", "pending_question" => approval)
      wait_for { prompts.last == "? " }
      typed << "n; use a PR"
      wait_for { prompts.last == "> " }
      push("type" => "question_requested", "pending_question" => approval.merge("id" => "a2"))
      wait_for { prompts.last == "? " }
      typed << ""
      wait_for { prompts.last == "> " }
      finish
      expect(client).to have_received(:answer).with(id: "a1", selected: ["Deny"], freeform: "use a PR")
      expect(client).to have_received(:dismiss_question).with(id: "a2")
      expect(screen.lines).to include("! execute: git push → Deny: use a PR", "! execute: git push → (denied)")
    end
  end

  it "re-asks after an invalid answer, and closes when another UI answers first" do
    start
    push("type" => "question_requested", "pending_question" => question)
    wait_for { prompts.last == "? " }

    typed << "9"
    wait_for { screen.lines.include?("Invalid choice '9': pick 1-3") }
    expect(screen.lines.last(2)).to eq(["? 9", "Invalid choice '9': pick 1-3"])
    push("type" => "question_answered", "id" => "q1", "answer" => { "selected" => ["Apple"], "freeform" => nil })
    wait_for { prompts.last == "> " }
    finish

    expect(screen.lines).to include("? Which one? → Apple (in another UI)")
  end

  it "clears the choices and says so when the turn ends with the question open" do
    start
    push("type" => "question_requested", "pending_question" => question)
    wait_for { screen.slots[:notes] }

    push("type" => "turn_canceled", "cancellation_reason" => "ctrl_c")
    wait_for { prompts.last == "> " }
    finish

    expect(screen.slots).not_to have_key(:notes)
    expect(screen.lines).to include("? Which one? → (the turn ended)")
  end

  it "reads the answer without echo (only the summary line stays)" do
    echo = []
    allow(Reline).to receive(:readline) { echo << !Thread.current[:samagotchi_reline_no_echo]; "2" }
    allow($stdin).to receive(:tty?).and_return(true)
    attached.instance_variable_set(:@question, Samagotchi::TerminalUI::QuestionPrompt.new(question))

    attached.send(:read_input_line, "? ", nil)

    expect(echo).to eq([false])
  end

  it "says so when its answer came too late" do
    allow(client).to receive(:answer)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"question_not_pending"}'))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "? " }

    typed << "1"
    wait_for { prompts.last == "> " }
    finish

    expect(screen.lines).to include("? Which one? → (already answered in another UI)")
  end

  it "dismisses the question on an empty answer, as the REPL does" do
    allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "? " }

    typed << "  "
    wait_for { prompts.last == "> " }
    # Every UI gets the cancel, this one too: it is already closed here.
    push("type" => "question_cancelled", "id" => "q1", "reason" => "dismissed")
    finish

    expect(client).to have_received(:dismiss_question).with(id: "q1")
    expect(screen.lines).to include("? Which one? → (cancelled)")
    expect(screen.lines.join("\n")).not_to include("(question cancelled)")
  end

  it "closes the question when it was answered or cancelled before the dismiss" do
    allow(client).to receive(:dismiss_question)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"question_not_pending"}'))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "? " }

    typed << ""
    wait_for { prompts.last == "> " }
    finish

    expect(screen.lines).to include("? Which one? → (question already closed in another UI)")
  end

  it "keeps the question open when the worker can't dismiss it" do
    allow(client).to receive(:dismiss_question)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: '{"error":"not_found"}'))
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "? " }

    typed << ""
    wait_for { screen.lines.last.to_s.end_with?("Ctrl-C cancels the turn") }
    finish

    expect(screen.lines).to include("this session's worker runs an older chi and can't dismiss questions; " \
                                    "restart it: chi sessions stop s-1234 && chi --resume s-1234 (its turns still work); " \
                                    "Ctrl-C cancels the turn")
    expect(prompts.last).to eq("? ")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "a failed turn's prompt" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:typed) { Queue.new }
  let(:reads) { Queue.new }

  before do
    allow(client).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1"}'))
    allow(client).to receive(:follow) do |&block|
      @push = block
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    # Each read reports its prefill, then blocks until the spec types.
    @thread = Thread.new { attached.run(input: ->(_prompt, prefill) { reads << prefill; typed.pop }) }
    expect(reads.pop(timeout: 2)).to be_nil
  end

  after do
    typed << nil
    @thread.join(2)
  end

  def fail_turn(enqueued_id)
    @push.call("type" => "turn_failed", "error_class" => "Samagotchi::LLM::ServerError", "summary" => "server error from host main: HTTP 500")
    @push.call("type" => "prompt_restored", "prompt" => "boom", "origin" => { "client_id" => "tui:1", "enqueued_id" => enqueued_id })
  end

  it "puts its own prompt back in the input, as the REPL does" do
    typed << "boom"
    expect(reads.pop(timeout: 2)).to be_nil

    fail_turn("e1")

    expect(reads.pop(timeout: 2)).to eq("boom")
    expect(screen.lines).to include("turn failed: server error from host main: HTTP 500", "(prompt restored for retry)")
  end

  it "leaves the input alone for a prompt it didn't send in this run (a replayed event, another UI)" do
    fail_turn("e-old")
    @push.call("type" => "prompt_restored", "prompt" => "theirs", "origin" => { "client_id" => "web:1", "enqueued_id" => "e2" })

    expect(reads.pop(timeout: 0.3)).to be_nil
    expect(screen.lines).not_to include("(prompt restored for retry)")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "commands and the continue offer" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }

  def feed(*events)
    events.each { |e| attached.handle_event(JSON.parse(JSON.generate(e))) }
  end

  def joined(continue_offer: nil)
    { type: :snapshot, snapshot: { messages: [], current_turn: nil, queued: [], continue_offer: continue_offer, event_seq: 1 } }
  end

  def ran(**fields)
    { type: :command_ran, command_id: "c1", client_id: "tui:1", line: "/model", status: "ok", output: "", changed: [],
      model_name: "m1" }.merge(fields)
  end

  before { feed(joined) }

  it "shows its own command's output as the REPL does: model> lines, a !cmd's own output as is" do
    feed(ran(line: "/model", output: "runtime model: m1 (profile=qwen36)"), ran(line: "!ls", output: "a\nb\n"))

    expect(screen.lines).to eq(["model> runtime model: m1 (profile=qwen36)", "a\nb\n"])
  end

  it "shows another UI's command with who sent it" do
    feed(ran(client_id: "web:tab", line: "/model x", output: "runtime model set to x (profile=qwen36)", changed: ["model"]))

    expect(screen.lines).to eq(["web> /model x", "model> runtime model set to x (profile=qwen36)"])
    expect(attached.model_name).to eq("m1")
  end

it "says a command waits for the turn to end, and puts ours back into the prompt" do
  reader = double("reader", prefill: true)
  attached.instance_variable_set(:@reader, reader)

  feed(ran(status: "busy", line: "!ls", output: "busy: wait for the turn to end"),
       ran(status: "busy", client_id: "web:tab", line: "/model x", output: "busy: wait for the turn to end"))

  expect(screen.lines.last(2)).to eq(["web> /model x", "busy: wait for the turn to end"])
  expect(reader).to have_received(:prefill).once.with("!ls")
end

it "points to the history when the prompt already holds text" do
  attached.instance_variable_set(:@reader, double("reader", prefill: false))

  feed(ran(status: "busy", line: "!ls", output: "busy: wait for the turn to end"))

  expect(screen.lines.last).to eq("(the command is in the input history: ↑)")
end

  it "asks at the ? prompt, its choices in the notes slot, while an offer is pending, from the join too" do
    expect(attached.send(:prompt_text)).to eq("> ")

    feed({ type: :continue_offered, context: { original_prompt: "task", last_model_intent: "run specs" }, no_interrupt: false })
    expect(attached.send(:prompt_text)).to eq("? ")
    expect(screen.slots[:notes]).to eq(["? The turn ran out of iterations. Continue it?", "  last step: run specs",
                                        "  yes: continue (Enter alone too)", "  no: stop here",
                                        "  no, <reason>: stop and tell the model why"])

    feed({ type: :continue_resolved, decision: "resume", client_id: "web:tab" })
    expect(attached.send(:prompt_text)).to eq("> ")
    expect(screen.slots).not_to have_key(:notes)
    # The web's "web> /continue yes" line says who answered.
    expect(screen.lines.grep(/Continue it\?/)).to be_empty

    feed({ type: :continue_offered, context: {}, no_interrupt: false },
         { type: :continue_resolved, decision: "dropped", client_id: "web:tab" })
    expect(screen.lines.last).to eq("? The turn ran out of iterations. Continue it? → (dropped: web sent a new prompt)")

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    other.handle_event(JSON.parse(JSON.generate(joined(continue_offer: { context: {}, no_interrupt: false }))))
    expect(other.send(:prompt_text)).to eq("? ")
    expect(screen.slots[:notes].first).to eq("? The turn ran out of iterations. Continue it?")
  end

  describe "context notes" do
    let(:note) { Samagotchi::ContextNote.message(note_id: "n1", text: "deploy frozen", source: "slack") }

    # This group has already joined: a join header needs a fresh UI.
    def join_fresh(messages)
      other = described_class.new(client: client, screen: screen, client_id: "tui:2")
      other.handle_event(JSON.parse(JSON.generate(joined.tap { |event| event[:snapshot][:messages] = messages })))
    end

    it "shows a note as one line: who sent it and its first line" do
      feed({ type: :context_added, label: "slack", text: "deploy frozen" },
           { type: :context_added, label: "session 3f2a1c (~/w/foo)", text: "api moved\nsee the wiki" },
           { type: :context_added, label: "cli", text: "x" * 100 },
           { type: :context_added, label: "cli", text: "#{"y" * 100}\nmore" })

      expect(screen.lines).to eq(["note from slack: deploy frozen",
                                  "note from session 3f2a1c (~/w/foo): api moved …",
                                  "note from cli: #{"x" * 59}…",
                                  "note from cli: #{"y" * 59}…"])
    end

    it "shows on join the notes that came after the last exchange, not older ones" do
      old = Samagotchi::ContextNote.message(note_id: "n0", text: "old news", source: "cli")
      join_fresh([{ role: "system", content: "sys" }, old, { role: "user", content: "hi" },
                  { role: "model", content: "hello there" }, note])

      expect(screen.lines).to eq(["user> hi", "hello there", "note from slack: deploy frozen"])
    end

    it "shows the notes of a session that has no exchange yet" do
      join_fresh([{ role: "system", content: "sys" }, note])

      expect(screen.lines).to eq(["note from slack: deploy frozen"])
    end
  end

  it "renders a reminder turn by its reminders, live and from a join" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "system:reminder" } },
         { type: :reminder_injected, reminders: [{ name: "stretch", description: "Stand up", interval_minutes: 1 }] })
    expect(screen.lines).to eq(["reminder: stretch"])

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    turn = { prompt: nil, continue: true, origin: { client_id: "system:reminder" },
             parts: [{ kind: "reminder", reminders: [{ name: "stretch" }, { name: "water" }] }] }
    other.handle_event(JSON.parse(JSON.generate(joined.merge(snapshot: joined[:snapshot].merge(current_turn: turn)))))
    expect(screen.lines.last).to eq("reminder: stretch, water")
  end

  it "renders a continue turn as (continuing), not as an empty prompt line" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "web:tab" } })

    expect(screen.lines.last).to eq("web> (continuing)")
  end

  it "points at !rollback after a cancelled prompt turn, not after a cancelled continue" do
    feed({ type: :turn_started, prompt: "go", origin: { client_id: "tui:1" } }, { type: :turn_canceled, cancellation_reason: "ctrl_c" })
    expect(screen.lines.last(2)).to eq(["turn cancelled (ctrl_c)", "partial progress kept in context; !rollback restores the pre-turn state"])

    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "tui:1" } }, { type: :turn_canceled, cancellation_reason: "ctrl_c" })
    expect(screen.lines.last).to eq("turn cancelled (ctrl_c)")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "answering the continue offer" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:typed) { Queue.new }
  let(:prompts) { [] }

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    expect(yield).to be_truthy
  end

  it "sends a bare answer as /continue <answer>, an empty one as /continue, and commands as they are" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    offer = { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [],
                                                    "continue_offer" => { "context" => {}, "no_interrupt" => false } } }
    allow(client).to receive(:follow) { |&block| block.call(offer) && double("stream", close: nil) }
    # Reads block until typed into, like Reline.
    thread = Thread.new { attached.run(input: ->(prompt, _prefill) { prompts << prompt; typed.pop }) }
    wait_for { prompts.last == "? " }

    ["no, too slow", "", "/model", nil].each { |line| typed << line }
    thread.join(2)

    # A command at the offer ran without echo: its line shows as typed.
    expect(screen.lines).to include("? /model")
    expect(screen.lines).not_to include("? no, too slow", "? ")

    expect(client).to have_received(:post_command).with(line: "/continue no, too slow", client_id: "tui:1")
    expect(client).to have_received(:post_command).with(line: "/continue", client_id: "tui:1")
    expect(client).to have_received(:post_command).with(line: "/model", client_id: "tui:1")
  end

  it "leaves one line with its own answer once the worker resolves the offer" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    attached.handle_event({ type: :continue_offered, context: {}, no_interrupt: false })

    attached.send(:submit, "maybe")
    expect(screen.lines.last).to eq("? maybe")
    attached.send(:submit, "no, too slow")
    attached.handle_event({ type: :continue_resolved, decision: "abort_with_reason", client_id: "tui:1" })

    expect(screen.lines.last).to eq("? The turn ran out of iterations. Continue it? → no, too slow")
    expect(screen.slots).not_to have_key(:notes)
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "launch flags" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:joined) { { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 } } }
  let(:ack) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1"}') }

  def ran(status, output) = { "type" => "command_ran", "command_id" => "c1", "client_id" => "tui:1", "line" => "/model fast",
                              "status" => status, "output" => output, "changed" => [], "model_name" => "m" }

  it "switches the model first, then sends the first prompt" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", first_command: "/model fast")

    attached.handle_event(joined)
    expect(client).not_to have_received(:post_turn)
    attached.handle_event(ran("ok", "runtime model set to fast (profile=qwen36)"))

    expect(client).to have_received(:post_command).with(line: "/model fast", client_id: "tui:1")
    expect(client).to have_received(:post_turn).with(prompt: "hi", client_id: "tui:1")
  end

  it "stops the launch when the switch doesn't go through, saying why" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    allow(client).to receive(:post_turn)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", first_command: "/model fast")

    attached.handle_event(joined)
    result = attached.handle_event(ran("busy", "busy: wait for the turn to end"))

    expect(result).to eq(:failed)
    expect(screen.lines.last).to eq("could not switch to the --model: busy: wait for the turn to end")
    expect(client).not_to have_received(:post_turn)
  end

  it "stops the launch when the worker can't take the command" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: "{}"))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/model fast")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to start_with("could not switch to the --model: this session's worker runs an older chi")
    expect(screen.lines.last).to include("chi sessions stop s-1234 && chi --resume s-1234")
  end

  it "posts every prompt with no_interrupt under --no-interrupt" do
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", no_interrupt: true)

    attached.handle_event(joined)

    expect(client).to have_received(:post_turn).with(prompt: "hi", client_id: "tui:1", no_interrupt: true)
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "input parity with the REPL" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:history_dir) { Dir.mktmpdir("attached-history") }
  let(:ack) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1","command_id":"c1"}') }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_HISTORY_FILE", "SAMAGOTCHI_DEFAULT_INPUT")
    ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(history_dir, "history.json")
    example.run
  ensure
    %w[SAMAGOTCHI_HISTORY_FILE SAMAGOTCHI_DEFAULT_INPUT].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(history_dir)
    Reline::HISTORY.clear
  end

  before do
    allow(client).to receive(:follow) do |&block|
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    allow(client).to receive_messages(post_turn: ack, post_command: ack)
  end

  def run_loop(inputs, **opts)
    reads = []
    described_class.new(client: client, screen: screen, client_id: "tui:1", **opts)
                   .run(input: ->(_prompt, prefill) { reads << prefill; inputs.shift })
    reads
  end

  it "keeps what was typed in the REPL's history file, and loads it on the next run" do
    run_loop(["hello", "!ls", "/model", "!rollback", "/stats"].tap { allow(client).to receive(:get_json) })

    expect(JSON.parse(File.read(ENV["SAMAGOTCHI_HISTORY_FILE"]))).to eq(["hello", "!ls"])
    Reline::HISTORY.clear
    run_loop([])
    expect(Reline::HISTORY.to_a).to eq(["hello", "!ls"])
  end

  it "sends #memory shorthand rewritten, as the REPL does" do
    run_loop(["check #notes and #project/todo"])

    expect(client).to have_received(:post_turn)
      .with(prompt: 'check memory "notes" and memory "todo" in project scope', client_id: "tui:1")
  end

  it "offers the attached commands on Tab, /quit too" do
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1")

    expect(attached.send(:assist_path_completion_candidates, "/q")).to eq(["/quit"])
    expect(attached.send(:assist_path_completion_candidates, "/mo")).to eq(%w[/model /models])
  end

  it "types the default input into a new session's first read, unless told not to" do
    ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Hey Chi, "

    expect(run_loop([nil], default_input: true)).to eq(["Hey Chi, "])
    expect(run_loop([nil], default_input: false)).to eq([nil])
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "idle status line" do
  let(:screen) { RecordingSurface.new(columns: 120) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_STATUS_LINE", "SAMAGOTCHI_DEFAULT_MODEL")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "m1"
    example.run
  ensure
    %w[SAMAGOTCHI_STATUS_LINE SAMAGOTCHI_DEFAULT_MODEL].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  def feed(*events)
    events.each { |e| attached.handle_event(JSON.parse(JSON.generate(e))) }
  end

  def join(model_name: "m1", used_memory_names: [])
    { type: :snapshot, snapshot: { messages: [], current_turn: nil, queued: [], event_seq: 1 },
      session_state_snapshot: { status: "idle", model_name: model_name, used_memory_names: used_memory_names } }
  end

  def status = screen.slots[:status]&.first

  it "shows the REPL's segments: the worker's model and the session's memories, from the join" do
    feed(join(used_memory_names: %w[notes todo]))

    expect(status).to eq("status> model=m1 | mem: notes, todo")
  end

  it "names the default when the worker runs another model, and follows /model" do
    feed(join(model_name: "m2"))
    expect(status).to eq("status> model=m2 (default: m1)")

    feed({ type: :command_ran, command_id: "c", client_id: "web:1", line: "/model clear", status: "ok",
           output: "runtime model reset to m1", changed: ["model"], model_name: "m1" })
    expect(status).to eq("status> model=m1")
  end

  it "shows the served model first when the server serves another one, until /model" do
    feed(join.merge(session_state_snapshot: { status: "idle", model_name: "m1", served_model: "ornith-1.5-35b",
                                              served_model_for: "m1" }))
    expect(status).to eq("status> model=ornith-1.5-35b (served; asked m1)")

    feed({ type: :command_ran, command_id: "c", client_id: "web:1", line: "/model m2", status: "ok",
           output: "runtime model set to m2", changed: ["model"], model_name: "m2" })
    expect(status).to eq("status> model=m2 (default: m1)")

    feed({ type: :generation_completed, iteration: 1, served_model: "m2-2026-01-01", requested_model: "m2" })
    expect(status).to eq("status> model=m2 (default: m1)")
    feed({ type: :generation_completed, iteration: 1, served_model: "ornith-1.5-35b", requested_model: "m2" })
    expect(status).to eq("status> model=ornith-1.5-35b (served; asked m2)")
  end

  it "cuts a long asked-for name in the status line" do
    feed(join(model_name: "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M").tap do |event|
      event[:session_state_snapshot].merge!(served_model: "ornith", served_model_for: "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M")
    end)

    expect(status).to start_with("status> model=ornith (served; asked unsloth/Qwen3.6-35B-A3B…)")
  end

  it "adds the context estimate and the memories a turn used" do
    feed(join,
         { type: :context_status, usage: { estimated_pct: 12.5 }, bucket: "low" },
         { type: :used_memories_updated, used_memory_names: ["notes"] })

    expect(status).to eq("status> model=m1 | ctx=12.5% (low) | mem: notes")
  end

  it "draws none with SAMAGOTCHI_STATUS_LINE=off" do
    ENV["SAMAGOTCHI_STATUS_LINE"] = "off"

    feed(join)

    expect(screen.slots).not_to have_key(:status)
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "Ctrl-C and exit at an idle prompt (D4)" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:now) { [0.0] }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", clock: -> { now.first }) }

  before do
    allow(client).to receive(:follow) do |&block|
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    allow(client).to receive(:cancel)
  end

  after { Samagotchi::TerminalUI::RelineSeam.interrupt_handler = nil }

  # Each entry is a read: a line, nil (Ctrl-D), or [:ctrl_c, typed, at] for a
  # Ctrl-C with +typed+ in the line at time +at+ (Reline's seam sees the text
  # before the read ends).
  def run_reads(*reads)
    attached.run(input: lambda do |_prompt, _prefill|
      entry = reads.shift
      return entry unless entry.is_a?(Array)

      _, typed, at = entry
      now[0] = at
      allow(Reline).to receive(:line_buffer).and_return(typed)
      Samagotchi::TerminalUI::RelineSeam.interrupt_handler&.call
      raise Interrupt
    end)
  end

  it "says how to detach on a first Ctrl-C at an empty prompt, and detaches on a second within 2 s" do
    expect(run_reads([:ctrl_c, "", 10.0], [:ctrl_c, "", 11.5])).to eq(:detached)

    expect(screen.lines).to include("Ctrl-D to detach, /exit stops the worker")
    expect(screen.lines.last).to start_with("Detached; the session keeps running.")
    expect(client).not_to have_received(:cancel)
  end

  it "only says it again when the second press comes later" do
    expect(run_reads([:ctrl_c, "", 10.0], [:ctrl_c, "", 13.0], nil)).to eq(:detached)

    expect(screen.lines.count("Ctrl-D to detach, /exit stops the worker")).to eq(2)
  end

  it "takes a Ctrl-C that cleared typed text as just that" do
    expect(run_reads([:ctrl_c, "half typed", 10.0], [:ctrl_c, "", 10.5], nil)).to eq(:detached)

    expect(screen.lines.count("Ctrl-D to detach, /exit stops the worker")).to eq(1)
  end

it "cancels a running turn on Ctrl-C and leaves the typed text in the prompt (the read goes on)" do
  allow(client).to receive(:follow) do |&block|
    block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => { "prompt" => "p", "parts" => [] },
                                                      "queued" => [], "event_seq" => 1 })
    double("stream", close: nil)
  end
  handled = nil

  attached.run(input: lambda do |_prompt, _prefill|
    allow(Reline).to receive(:line_buffer).and_return("half typed")
    handled = Samagotchi::TerminalUI::RelineSeam.interrupt_handler.call
    nil # then Ctrl-D, in the same read
  end)

  expect(handled).to be(true)
  expect(client).to have_received(:cancel).with(reason: "ctrl_c")
end

  it "asks the worker to exit on a bare exit, any case, as the REPL exits" do
    allow(client).to receive(:request_exit).and_return(Samagotchi::BridgeClient::Response.new(status: 200, body: '{"status":"exiting"}'))

    expect(run_reads("exit")).to eq(:detached)
    expect(described_class.new(client: client, screen: screen, client_id: "tui:1").run(input: ->(_p, _f) { "EXIT" })).to eq(:detached)
    expect(client).to have_received(:request_exit).twice.with(client_id: "tui:1")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "/exit and /detach" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:stream) { double("stream", close: nil) }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:idle) { { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 } }

  def response(status, body = "{}") = Samagotchi::BridgeClient::Response.new(status: status, body: body)

  # With +at+, the lines are typed once a read opens at that prompt (a
  # continue offer or a question restarts the first read).
  def run_lines(*lines, snapshot: idle, at: nil)
    allow(client).to receive(:follow) do |**, &block|
      block.call("type" => "snapshot", "snapshot" => snapshot)
      stream
    end
    return attached.run(input: ->(_prompt, _prefill) { lines.shift }) unless at

    typed = Queue.new
    prompts = Queue.new
    thread = Thread.new { attached.run(input: ->(prompt, _prefill) { prompts << prompt; typed.pop }) }
    Timeout.timeout(2) { nil until prompts.pop.include?(at) }
    lines.each { |line| typed << line }
    thread.value
  end

  it "follows the stream under its client id, so the worker doesn't count its own stream as another UI" do
    run_lines(nil)

    expect(client).to have_received(:follow).with(client_id: "tui:1")
  end

  %w[/exit /quit /QUIT exit].each do |line|
    it "detaches on #{line} and asks the worker to exit, which it will" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

      expect(run_lines(line)).to eq(:detached)

      expect(client).to have_received(:request_exit).with(client_id: "tui:1")
      expect(screen.lines.last).to eq("Detached; the session's worker is stopping. Resume with: chi --resume s-1234")
      expect(stream).to have_received(:close)
    end
  end

  {
    "turn_running" => "a turn is running", "input_queued" => "prompts are queued",
    "continue_offered" => "a continue offer is pending", "client_connected" => "another UI is attached",
    "reminders" => "reminders are set", "starting" => "the worker is still starting", "something_new" => "something_new"
  }.each do |reason, words|
    it "says what keeps the worker up when it holds (#{reason})" do
      allow(client).to receive(:request_exit).and_return(response(409, %({"status":"held","reason":"#{reason}"})))

      expect(run_lines("/exit")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached; the session keeps running (#{words}). Re-attach with: chi --attach s-1234")
    end
  end

  it "says how to stop an older worker that has no exit route" do
    allow(client).to receive(:request_exit).and_return(response(404, '{"error":"not_found"}'))

    run_lines("/exit")

    expect(screen.lines.last).to eq("Detached; this worker runs an older chi and can't be stopped from here: chi sessions stop s-1234")
  end

  [
    [404, '{"error":"unknown_session"}', "404 unknown_session"],
    [0, nil, "no reply"],
    [500, '{"error":"bridge_error","detail":"boom"}', "500 boom"]
  ].each do |status, body, why|
    it "detaches and says the request didn't go through (#{why})" do
      allow(client).to receive(:request_exit).and_return(response(status, body))

      expect(run_lines("/exit")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached (could not ask the worker to stop: #{why}). Re-attach with: chi --attach s-1234")
    end
  end

  it "detaches when the Bridge is gone" do
    allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)

    expect(run_lines("/exit")).to eq(:detached)

    expect(screen.lines.last).to start_with("Detached (could not ask the worker to stop: Connection refused")
    expect(screen.lines.last).to end_with("Re-attach with: chi --attach s-1234")
  end

  describe "/exit --delete" do
    let(:deleted) { [] }
    let(:delete_session) { ->(id) { deleted << id } }
    let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", delete_session: delete_session) }

    %w[/exit /quit exit].each do |command|
      it "asks the worker to exit, then deletes the session (#{command} --delete)" do
        allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

        expect(run_lines("#{command} --delete")).to eq(:detached)

        expect(client).to have_received(:request_exit).with(client_id: "tui:1")
        expect(deleted).to eq(["s-1234"])
        expect(screen.lines.last).to eq("Detached; deleted session s-1234.")
      end
    end

    it "deletes nothing when the worker stays up, and says why" do
      allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"client_connected"}'))

      run_lines("/exit --delete")

      expect(deleted).to be_empty
      expect(screen.lines.last).to eq("Detached; not deleted: the session keeps running (another UI is attached). " \
                                      "Re-attach with: chi --attach s-1234")
    end

    it "deletes nothing when the exit request fails" do
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)

      run_lines("/exit --delete")

      expect(deleted).to be_empty
      expect(screen.lines.last).to start_with("Detached (could not ask the worker to stop: Connection refused")
      expect(screen.lines.last).to end_with("Not deleted.")
    end

    it "says how to finish when the delete is refused after the exit" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))
      refusing = ->(id) { raise Samagotchi::SessionManager::DeleteRefused.new(id, :still_stopping) }
      loop_ui = described_class.new(client: client, screen: screen, client_id: "tui:1", delete_session: refusing)
      allow(client).to receive(:follow) do |**, &block|
        block.call("type" => "snapshot", "snapshot" => idle)
        stream
      end

      loop_ui.run(input: ->(_prompt, _prefill) { "/exit --delete" })

      expect(screen.lines.last).to eq("Detached; the worker is stopping, but session s-1234 was not deleted " \
                                      "(session s-1234's worker is still shutting down): chi sessions delete s-1234")
    end

    it "takes any other /exit argument as a prompt, not an exit" do
      allow(client).to receive(:request_exit)
      allow(client).to receive(:post_turn).and_return(response(202, '{"status":"accepted","enqueued_id":"e1"}'))

      run_lines("/exit --now", nil)

      expect(client).not_to have_received(:request_exit)
      expect(deleted).to be_empty
    end
  end

  it "only detaches on /detach (any case) and Ctrl-D, leaving the worker up" do
    allow(client).to receive(:request_exit)
    allow(client).to receive(:post_turn)

    expect(run_lines("/detach")).to eq(:detached)
    expect(run_lines("/DETACH")).to eq(:detached)
    expect(run_lines(nil)).to eq(:detached)

    expect(client).not_to have_received(:request_exit)
    expect(client).not_to have_received(:post_turn)
    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --attach s-1234")
  end

  it "detaches on /detach at a continue offer instead of answering it" do
    allow(client).to receive(:post_command)

    expect(run_lines("/detach", snapshot: idle.merge("continue_offer" => { "context" => {}, "no_interrupt" => false }),
                               at: "? ")).to eq(:detached)

    expect(client).not_to have_received(:post_command)
  end

  it "asks the worker on /exit at a continue offer, which then holds" do
    allow(client).to receive(:post_command)
    allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"continue_offered"}'))

    run_lines("/exit", snapshot: idle.merge("continue_offer" => { "context" => {}, "no_interrupt" => false }),
                       at: "? ")

    expect(client).not_to have_received(:post_command)
    expect(screen.lines.last).to include("(a continue offer is pending)")
  end

  it "reads /exit at an open question as an answer to it" do
    allow(client).to receive(:request_exit)
    question = { "id" => "q1", "question" => "Pick", "options" => %w[a b] }
    turn = { "prompt" => "p", "parts" => [], "pending_question" => question }

    run_lines("/exit", nil, snapshot: idle.merge("current_turn" => turn), at: "? ")

    expect(screen.lines).to include("Unknown option '/exit'. Use numbers 1-2 or exact labels.")
    expect(client).not_to have_received(:request_exit)
  end

  it "offers /detach and /quit on Tab" do
    expect(attached.send(:assist_path_completion_candidates, "/d")).to eq(["/detach"])
    expect(attached.send(:assist_path_completion_candidates, "/q")).to eq(["/quit"])
  end
end
