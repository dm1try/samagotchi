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
                                    "restart it to use them (its turns still work)")
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
    @thread = Thread.new { attached.run(input: ->(prompt, _prefill) { prompts << prompt; typed.pop }) }
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

    expect(screen.lines.drop(1)).to eq(["model> runtime model: m1 (profile=qwen36)", "a\nb\n"])
  end

  it "shows another UI's command with who sent it" do
    feed(ran(client_id: "web:tab", line: "/model x", output: "runtime model set to x (profile=qwen36)", changed: ["model"]))

    expect(screen.lines.drop(1)).to eq(["web> /model x", "model> runtime model set to x (profile=qwen36)"])
    expect(attached.model_name).to eq("m1")
  end

  it "says a command waits for the turn to end" do
    feed(ran(status: "busy", output: "busy: wait for the turn to end"))

    expect(screen.lines.last).to eq("busy: wait for the turn to end")
  end

  it "asks at the continue prompt while an offer is pending, from the join too" do
    expect(attached.send(:prompt_text)).to eq("> ")

    feed({ type: :continue_offered, context: { original_prompt: "task" }, no_interrupt: false })
    expect(attached.send(:prompt_text)).to eq(Samagotchi::TerminalUI::CONTINUE_PROMPT)

    feed({ type: :continue_resolved, decision: "resume", client_id: "web:tab" })
    expect(attached.send(:prompt_text)).to eq("> ")
    # The web's "web> /continue yes" line says who answered.
    expect(screen.lines.grep(/continue offer/)).to be_empty

    feed({ type: :continue_offered, context: {}, no_interrupt: false },
         { type: :continue_resolved, decision: "dropped", client_id: "web:tab" })
    expect(screen.lines.last).to eq("(the continue offer was dropped: web sent a new prompt)")

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    other.handle_event(JSON.parse(JSON.generate(joined(continue_offer: { context: {}, no_interrupt: false }))))
    expect(other.send(:prompt_text)).to eq(Samagotchi::TerminalUI::CONTINUE_PROMPT)
  end

  it "renders a reminder turn by its reminders, live and from a join" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "system:reminder" } },
         { type: :reminder_injected, reminders: [{ name: "stretch", description: "Stand up", interval_minutes: 1 }] })
    expect(screen.lines.drop(1)).to eq(["reminder: stretch"])

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
    wait_for { prompts.last == Samagotchi::TerminalUI::CONTINUE_PROMPT }

    ["no, too slow", "", "/model", nil].each { |line| typed << line }
    thread.join(2)

    expect(client).to have_received(:post_command).with(line: "/continue no, too slow", client_id: "tui:1")
    expect(client).to have_received(:post_command).with(line: "/continue", client_id: "tui:1")
    expect(client).to have_received(:post_command).with(line: "/model", client_id: "tui:1")
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
  end

  it "posts every prompt with no_interrupt under --no-interrupt" do
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", no_interrupt: true)

    attached.handle_event(joined)

    expect(client).to have_received(:post_turn).with(prompt: "hi", client_id: "tui:1", no_interrupt: true)
  end
end
