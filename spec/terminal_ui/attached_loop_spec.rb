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
      allow(Samagotchi::Log).to receive(:info).and_call_original
      feed(snapshot(messages: [{ role: "system", content: "sys" }, { role: "user", content: "hi" },
                               { role: "model", content: "hello there" }]))

      expect(screen.lines).to eq(["user> hi", "hello there"])
      expect(Samagotchi::Log).to have_received(:info).with(:attached, "joined", session: "s-1234", messages: 2, notes: 0)
      expect(Samagotchi::Log.session_id).to eq("s-1234")
      expect(attached).not_to be_running
    end

    it "moves to a new worker (a restart): requests go there, and its snapshot resyncs without repeating the join" do
      allow(client).to receive(:host).and_return("127.0.0.1")
      feed(snapshot(messages: [{ role: "user", content: "hi" }, { role: "model", content: "hello there" }]))
      moved_snapshot = snapshot(messages: [{ role: "user", content: "hi" }, { role: "model", content: "hello there" }])
      moved_snapshot[:snapshot][:chi_version] = "0.19.0"
      feed({ type: "worker_changed", port: 4321 }, moved_snapshot)

      moved = attached.instance_variable_get(:@client)
      expect([moved.session_id, moved.port, moved.host]).to eq(["s-1234", 4321, "127.0.0.1"])
      expect(screen.lines).to eq(["user> hi", "hello there", "chi> the session's worker restarted on chi 0.19.0"])
    end

    describe "chi versions at the join" do
      def attach_with(installed:, worker:)
        loop = described_class.new(client: client, screen: screen, client_id: "tui:1", installed_version: -> { installed })
        joined = snapshot
        joined[:snapshot][:chi_version] = worker
        loop.handle_event(JSON.parse(JSON.generate(joined)))
      end

      it "says how to move a worker older than the newest chi installed" do
        attach_with(installed: "99.0.0", worker: Samagotchi::VERSION)
        expect(screen.lines.last).to start_with("chi> chi 99.0.0 is installed; this session's worker runs " \
                                                "#{Samagotchi::VERSION} and this terminal #{Samagotchi::VERSION}.")
      end

      it "says nothing when all of it is current, or the worker doesn't say its version" do
        attach_with(installed: Samagotchi::VERSION, worker: Samagotchi::VERSION)
        attach_with(installed: "99.0.0", worker: nil)
        expect(screen.lines.grep(/chi>/)).to be_empty
      end
    end

    it "looks for the session's live worker for the stream, and gives up once the session was stopped" do
      allow(client).to receive(:host).and_return("127.0.0.1")
      found = instance_double(Samagotchi::BridgeClient)
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(found)
      allow(Samagotchi::Session).to receive(:stopped_marker?).with("s-1234").and_return(false)
      expect(attached.send(:live_worker)).to be(found)
      expect(Samagotchi::BridgeClient).to have_received(:discover)
        .with("s-1234", session_dir: Samagotchi::Session.session_dir("s-1234"), host: "127.0.0.1")

      allow(Samagotchi::Session).to receive(:stopped_marker?).with("s-1234").and_return(true)
      expect(attached.send(:live_worker)).to eq(:gone)
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

    it "adds an edit's +N −M to its tool line on a join" do
      turn = { prompt: "go", origin: nil,
               parts: [{ kind: "tool", tool: "edit", params: "path=k", status: "ok", diff: { text: "x", added: 3, removed: 1 } }] }
      feed(snapshot(current_turn: turn))
      expect(screen.lines).to include("tool> edit path=k: ok +3 \u22121")
    end

    it "does not repeat the joined turn's earlier tools in its summary" do
      activity = { action: "reading file", tool: "read", params: "path=log", status: "ok" }
      turn = { prompt: "go", origin: nil, parts: [{ kind: "tool", tool: "read", params: "path=log", status: "ok" }] }
      feed(snapshot(current_turn: turn), { type: :turn_completed, turn_summary: summary("done", tool_activity: [activity]) })

      expect(screen.lines).to eq(["user> go", "tool> read path=log: ok", "done"])
      expect(attached).not_to be_running
    end

    # Shared with the web: spec/shared/turn_snapshot.json.
    it "replays the joined turn as it was drawn live: tool rows with their action and duration" do
      fixture = JSON.parse(File.read(File.expand_path("../shared/turn_snapshot.json", __dir__)))
      joined = snapshot(current_turn: fixture.dig("snapshot", "current_turn"), queued: fixture.dig("snapshot", "queued"))
      feed(joined)

      expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }).to eq([
        "web> do it",
        'tool> Running command (execute command="ls"): ok (1.3s)',
        "tool> Editing file (edit path=\"a.rb\"): ok (40ms) +1 −1",
        "input> also this",
        "check-in> nudged: keep going",
        "reminder: r",
        "known-names> rejected execute",
        "↻ cut by loop-guard, asking again (1/1)",
        # A snapshot from an older worker: no action, the tool's row.
        'tool> read path="old.rb": ok',
        "queued web> later"
      ])
      expect(screen.statuses.last).to eq("| running read…")
    end

    it "leaves the last answer's thinking and tool-call markup out, keeping its layout" do
      answer = "<think>\nplan it\n</think>\n\nHere:\n```\ndef a\n    b = 1\nend\n```"
      feed(snapshot(messages: [{ role: "user", content: "code" }, { role: "model", content: answer }]))

      expect(screen.lines).to eq(["user> code", "Here:\n```\ndef a\n    b = 1\nend\n```"])
    end

    it "shows the last model message with text when the latest is only a tool call (one never answered)" do
      feed(snapshot(messages: [{ role: "user", content: "go" }, { role: "model", content: "<think>a</think>Looking." },
                               { role: "tool_response", content: "r" },
                               { role: "model", content: "<think>b</think>\n<tool_call>\n<function=read>\n</function>\n</tool_call>" }]))

      expect(screen.lines).to eq(["user> go", 'tool> reading file (read path=""): no result', "Looking."])
    end

    it "shows the last exchange's tool calls as the live tool rows, between the prompt and the answer" do
      feed(snapshot(messages: [{ role: "user", content: "find it" },
                               { role: "model", content: "Searching.", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "true" } }] },
                               { role: "tool_response", tool_call_id: "c1", content: "exit: 0" },
                               { role: "model", content: "Searching.", tool_calls: [{ id: "c2", name: "read", arguments: { path: "NOPE.md" } }] },
                               { role: "tool_response", tool_call_id: "c2", content: "Error: no such file" },
                               { role: "model", content: "Done." }]))

      expect(screen.lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                  'tool> reading file (read path="NOPE.md"): error', "Done."])
    end

    it "shows a last turn that ended with no answer as the notice, not an earlier step's text" do
      feed(snapshot(messages: [{ role: "user", content: "go" },
                               { role: "model", content: "Looking.", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "true" } }] },
                               { role: "tool_response", tool_call_id: "c1", content: "exit: 0" },
                               Samagotchi::TurnNote.empty(retries: 1, steps: [{ role: "model", content: "<think>x</think>" }])]))

      expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") })
        .to eq(["user> go", 'tool> running command (execute command="true"): ok',
                "no answer: the model returned nothing (after 1 retry)"])
    end

    it "still shows an older session's [No response] as it was saved" do
      feed(snapshot(messages: [{ role: "user", content: "go" }, { role: "model", content: "[No response]" },
                               Samagotchi::TurnNote.empty.except(:empty_answer)]))

      expect(screen.lines).to eq(["user> go", "[No response]"])
    end

    context "with the session's saved tool records" do
      def save_records(records)
        dir = Samagotchi::Session.session_dir("s-1234")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "analytics.json"), JSON.generate("tool_records" => records))
      end

      let(:messages) do
        [{ role: "user", content: "find it", turn_id: "t1" },
         { role: "model", content: "Searching.", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "true" } }] },
         { role: "tool_response", tool_call_id: "c1", content: "exit: 0" },
         { role: "model", content: "Searching.", tool_calls: [{ id: "c2", name: "read", arguments: { path: "NOPE.md" } }] },
         { role: "tool_response", tool_call_id: "c2", content: "Error: no such file" },
         { role: "model", content: "Done." }]
      end

      after { FileUtils.rm_rf(Samagotchi::Session.session_dir("s-1234")) }

      it "gives each replayed tool row its duration from the turn's records, as the live rows show it" do
        save_records([{ turn_id: "t0", iteration: 1, call_index: 1, tool: "execute", duration_ms: 9000 },
                      { turn_id: "t1", iteration: 1, call_index: 1, tool: "execute", duration_ms: 1234 },
                      { turn_id: "t1", iteration: 2, call_index: 1, tool: "read", duration_ms: 42 }])
        feed(snapshot(messages: messages))

        expect(screen.lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok (1.2s)',
                                    'tool> reading file (read path="NOPE.md"): error (42ms)', "Done."])
      end

      it "pairs the rows with the records in call order by tool, leaving a row without one bare" do
        # The first call left no record (an older worker's turn, say): the
        # read's record is not the execute's.
        save_records([{ turn_id: "t1", iteration: 2, call_index: 1, tool: "read", duration_ms: 42 }])
        feed(snapshot(messages: messages))

        expect(screen.lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                    'tool> reading file (read path="NOPE.md"): error (42ms)', "Done."])
      end

      it "shows no durations for a prompt without a turn id (an older session)" do
        save_records([{ turn_id: "t1", iteration: 1, call_index: 1, tool: "execute", duration_ms: 1234 }])
        feed(snapshot(messages: [messages.first.except(:turn_id), *messages.drop(1)]))

        expect(screen.lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                    'tool> reading file (read path="NOPE.md"): error', "Done."])
      end
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
      feed({ type: :turn_canceled, cancellation_reason: :ctrl_c, duration_ms: 3100 })

      expect(screen.lines.last(2)).to eq(["✕ turn canceled (Ctrl-C) · 3.1s", "  #{Samagotchi::TerminalUI::Formatting::ROLLBACK_HINT}"])
      expect(screen.statuses.last).to be_nil
      expect(attached).not_to be_running
    end

    it "shows a failed turn's error" do
      feed({ type: :turn_failed, error_class: "Samagotchi::Client::RetryExhausted", message: "server down" })

      expect(screen.lines.last).to eq("✕ turn failed: server down")
      expect(attached).not_to be_running
    end

    it "shows a provider error's one-line summary" do
      feed({ type: :turn_failed, error_class: "Samagotchi::LLM::AuthError", message: "fw: set FW_KEY",
             error_kind: :auth, retryable: false, host: "fw", summary: "auth failed for host fw: set FW_KEY" })

      expect(screen.lines.last).to eq("✕ turn failed: auth failed for host fw: set FW_KEY")
    end
  end

  describe "the recap on return" do
    it "shows the saved recap when joining, before the last exchange, noting the turns since" do
      joined = snapshot(messages: [{ role: "user", content: "hi" }, { role: "model", content: "hello" }])
      joined[:snapshot][:saved_recap] = { text: "We set up Bluefin.", covered: 2, turns_since: 1 }
      feed(joined)

      expect(screen.lines.first(2)).to eq(["recap (before the last turn)> We set up Bluefin.", "user> hi"])
    end

    it "shows it once, not again on a resync" do
      joined = snapshot
      joined[:snapshot][:saved_recap] = { text: "We set up Bluefin.", covered: 2, turns_since: 0 }
      feed(joined, joined.merge(type: :reset))

      expect(screen.lines.grep(/Bluefin/)).to eq(["recap> We set up Bluefin."])
    end

    it "prints a recap written while it sits idle" do
      feed(snapshot, { type: :recap_ready, recap: "We fixed the bug.", generation: 3, covered: 4 })

      expect(screen.lines.last).to eq("recap> We fixed the bug.")
    end

    it "ignores one that lands after a turn started" do
      feed(snapshot, { type: :turn_started, prompt: "next", origin: { client_id: "web:1" } },
           { type: :recap_ready, recap: "stale", generation: 3, covered: 4 })

      expect(screen.lines.grep(/stale/)).to be_empty
    end
  end

  it "shows the guardrail load warning a snapshot carries when joining" do
    joined = snapshot
    joined[:snapshot][:guardrail_warning] = "hook g.rb (config) failed to load (LoadError: x)"
    feed(joined)

    expect(screen.lines).to include("guardrails> hook g.rb (config) failed to load (LoadError: x)")
  end

  it "shows the plugins' load warning, from a snapshot and live, labelled plugins" do
    joined = snapshot
    joined[:snapshot][:plugin_warning] = "plugin plugin.rb (bundle b) failed to load (x)"
    feed(joined, { type: :guardrail_warning, message: "plugin p.rb (bundle c) failed to load (y)", label: "plugins" })

    expect(screen.lines).to include("plugins> plugin plugin.rb (bundle b) failed to load (x)",
                                    "plugins> plugin p.rb (bundle c) failed to load (y)")
  end

  it "shows a hook's notice, live and from a snapshot's turn parts" do
    feed({ type: :hook_notice, hook: "known_names.rb (bundle known-names)", text: "rejected execute", level: "info" })
    expect(screen.lines.last).to eq("known-names> rejected execute")

    turn = { prompt: "go", parts: [{ kind: "notice", event: { type: "hook_notice", hook: "turn hook", text: "careful", level: "warn" } }] }
    feed(snapshot(current_turn: turn, type: :reset))
    expect(screen.lines).to include("hook> warning: careful")
  end

  it "shows a joined turn's retry rows where they came, and asks no answered question again" do
    question = { id: "q1", question: "Which?", options: %w[A B], status: "pending" }
    turn = { prompt: "go", parts: [
      { kind: "notice", event: { type: "empty_answer_retry", iteration: 1, attempt: 1, of: 1 } },
      { kind: "tool", iteration: 1, call_index: 1, tool: "read", params: "path=x", status: "ok", output: "x" },
      { kind: "notice", event: { type: "question_requested", pending_question: question } },
      { kind: "notice", event: { type: "question_answered", id: "q1", answer: { selected: ["A"] } } },
      { kind: "notice", event: { type: "empty_answer_retry", iteration: 2, attempt: 1, of: 1, stopped_by: "loop-guard" } }
    ] }
    feed(snapshot(current_turn: turn))

    plain = screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }
    first = plain.index("↻ empty answer, asking again (1/1)")
    cut = plain.index("↻ cut by loop-guard, asking again (1/1)")
    expect(first).not_to be_nil
    expect(cut).to be > first
    expect(plain[first + 1...cut].join("\n")).to include("read")
    expect(plain.join("\n")).not_to include("Which?")
  end

  describe "cards" do
    def lines = screen.lines.flat_map { |line| line.split("\n") }

    def card(id, title, **extra)
      { type: "card", id: id, source: "sample-plugin", title: title, body: "b", level: "info",
        actions: [{ label: "Again", command: "/hello again" }] }.merge(extra)
    end

    it "prints a live card as a block, and one shown again marked (updated)" do
      feed(snapshot, card("c1", "Hello"), card("c1", "Hello 2"))
      expect(lines).to include("┌ Hello · sample-plugin", "│ b", "│ → /hello again  Again", "└",
                                      "┌ Hello 2 (updated) · sample-plugin")
    end

    it "shows a snapshot's cards and notices since the last turn when joining, the running turn's after it" do
      joined = snapshot(current_turn: { prompt: "go", parts: [] })
      joined[:snapshot][:cards] = [
        card("old", "Old", turns_since: 1, current: false),
        { type: "hook_notice", hook: "plugin.rb (bundle sample-plugin)", text: "saved", level: "info", turns_since: 0, current: false },
        # A turn's own notices: the last turn's steps aren't shown, the running one's come with its parts.
        { type: "hook_notice", hook: "plugin.rb (bundle sample-plugin)", text: "last turn's", level: "info", in_turn: true, iteration: 1, calls: 0,
          turns_since: 0, current: false },
        { type: "hook_notice", hook: "plugin.rb (bundle sample-plugin)", text: "running turn's", level: "info", in_turn: true, turns_since: 0, current: true },
        { type: "empty_answer_retry", attempt: 1, of: 1, in_turn: true, iteration: 1, calls: 0, turns_since: 0, current: false },
        card("new", "New", turns_since: 0, current: false, updated: true),
        card("mid", "Mid", in_turn: true, turns_since: 0, current: true)
      ]
      feed(joined)

      titles = lines.grep(/\A┌|sample-plugin> /)
      expect(titles).to eq(["sample-plugin> saved", "┌ New (updated) · sample-plugin", "┌ Mid · sample-plugin"])
      expect(lines.index("┌ Mid · sample-plugin")).to be > lines.index { |line| line.include?("go") }
    end

    it "shows another client's anytime command line at its command_queued, before its cards, once" do
      feed(snapshot,
           { type: :command_queued, command_id: "a1", client_id: "web:1", line: "/btw why?", anytime: true },
           card("b1", "btw: why?", anytime: true),
           { type: :command_ran, command_id: "a1", client_id: "web:1", line: "/btw why?", status: "ok", output: "",
             changed: [], anytime: true },
           { type: :command_queued, command_id: "m1", client_id: "web:1", line: "/model" })

      shown = lines.grep(/btw|model/)
      expect(shown).to eq(["web> /btw why?", "┌ btw: why? · sample-plugin"])
    end

    it "shows no line for another client's card action (the card is its echo), anytime or not" do
      feed(snapshot,
           { type: :command_queued, command_id: "n1", client_id: "web:1", line: "/checkin nudge", anytime: true, card: true },
           { type: :command_ran, command_id: "n1", client_id: "web:1", line: "/checkin nudge", status: "ok", output: "",
             changed: [], anytime: true, card: true },
           { type: :command_ran, command_id: "n2", client_id: "web:1", line: "/checkin later", status: "ok", output: "",
             changed: [], card: true })

      expect(lines.grep(/checkin/)).to eq([])
    end

    it "on a resync shows only the cards not shown yet" do
      feed(snapshot, card("c1", "Hello"))
      resync = snapshot(type: :reset)
      resync[:snapshot][:cards] = [card("c1", "Hello", turns_since: 0), card("c2", "Other", turns_since: 3)]
      feed(resync)
      expect(lines.grep(/\A┌/)).to eq(["┌ Hello · sample-plugin", "┌ Other · sample-plugin"])
    end

    it "on a resync onto a new worker leaves out the cards an earlier worker saved (earlier turns' cards)" do
      feed(snapshot)
      resync = snapshot(type: :reset)
      resync[:snapshot][:cards] = [card("old", "Old", turns_since: 2).merge(earlier: true), card("new", "New", turns_since: 0)]
      feed(resync)
      expect(lines.grep(/\A┌/)).to eq(["┌ New · sample-plugin"])
    end
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

  describe "a worker that doesn't answer or can't be reached" do
    let(:timeout) { Errno::ETIMEDOUT.new("bridge turn: no reply within 30s") }
    let(:refused) { Errno::ECONNREFUSED.new('connect(2) for "127.0.0.1" port 1') }

    it "stays up and says why a prompt wasn't sent" do
      allow(client).to receive(:post_turn).and_raise(timeout)

      expect(run_with(["hello", nil])).to eq(:detached)
      allow(client).to receive(:post_turn).and_raise(refused)
      expect(run_with(["again", nil])).to eq(:detached)

      expect(screen.lines).to include("could not send the prompt (worker not answering: no reply within 30s)",
                                      "could not send the prompt (worker unreachable: connection refused)")
    end

    # The Bridge read it after its deadline (a slow worker) and dropped it.
    it "says a prompt the worker dropped as too late wasn't sent" do
      reply = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
      allow(client).to receive(:post_turn).and_return(reply)

      expect(run_with(["hello", nil])).to eq(:detached)

      expect(screen.lines).to include("could not send the prompt (worker not answering in time)")
    end

    it "stays up and says why a command didn't run" do
      allow(client).to receive(:post_command).and_raise(timeout)

      expect(run_with(["/models", nil])).to eq(:detached)

      expect(screen.lines).to include("could not run the command (worker not answering: no reply within 30s)")
    end

    # The Bridge read it after its deadline and dropped it: it didn't run.
    it "says a command the worker dropped as too late didn't run" do
      reply = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
      allow(client).to receive(:post_command).and_return(reply)

      expect(run_with(["!echo hi", nil])).to eq(:detached)

      expect(screen.lines).to include("could not run the command (worker not answering in time)")
    end

    it "stays up when Ctrl-C can't reach the worker to cancel the turn" do
      allow(client).to receive(:cancel).and_raise(refused)

      expect(run_with([:interrupt, nil], first: snapshot(current_turn: { "prompt" => "p", "parts" => [] }))).to eq(:detached)

      expect(screen.lines).to include("could not cancel the turn (worker unreachable: connection refused)")
    end
  end

  it "shows /stats from the worker's live metrics" do
    metrics = { turns: 2, tool_calls_total: 1, tool_errors: 0, tool_calls_by_tool: { read: 1 }, iterations_total: 3,
                tokens: { prompt_sum: 10, completion_sum: 5, source: "server" }, gen_latency_ms: 120,
                cancellations: 0, retries: 0 }
    allow(client).to receive(:get_json).with("stats")
      .and_return(JSON.parse(JSON.generate(metrics: metrics.merge(context: { used_tokens: 12_800, window_tokens: 128_000, window_source: "server" }))))

    run_with(["/stats"])

    expect(screen.lines).to include(a_string_including("turns:            2"),
                                    a_string_including("tokens in/out:    10/5 (all requests, server-reported)"),
                                    a_string_including("context used:     12800 tokens (10.0%)"),
                                    a_string_including("context window:   128000 tokens (server)"))
  end

  it "reads /stats from /state on a worker without the stats route" do
    allow(client).to receive(:get_json).with("stats").and_return(nil)
    allow(client).to receive(:get_json).with("state")
      .and_return(JSON.parse(JSON.generate(session_state_snapshot: { metrics: { turns: 4 } })))

    run_with(["/stats"])

    expect(screen.lines).to include(a_string_including("turns:            4"))
  end

  describe "/recap" do
    def recap_reply(body) = Samagotchi::BridgeClient::Response.new(status: 200, body: JSON.generate(body))

    it "says how recap is turned off when it is" do
      allow(client).to receive(:request_recap).and_return(recap_reply(enabled: false))

      run_with(["/recap"])

      expect(screen.lines).to include(a_string_starting_with("recap is off (recap: false in config.yml"))
    end

    it "shows the saved recap, and that a new one is being written" do
      allow(client).to receive(:request_recap)
        .and_return(recap_reply(enabled: true, min_user_turns: 2, request: "started",
                                saved: { text: "We fixed the bug.", covered: 4, turns_since: 2 }))

      run_with(["/recap"])

      expect(screen.lines).to include("recap (before the last 2 turns)> We fixed the bug.\nwriting a recap…")
    end

    it "says when nothing new was said since" do
      allow(client).to receive(:request_recap)
        .and_return(recap_reply(enabled: true, min_user_turns: 2, request: "nothing_new",
                                saved: { text: "We fixed the bug.", covered: 4, turns_since: 0 }))

      run_with(["/recap"])

      expect(screen.lines).to include("recap> We fixed the bug.\n(nothing new since this recap)")
    end

    it "says what it needs while there is none yet" do
      allow(client).to receive(:request_recap)
        .and_return(recap_reply(enabled: true, min_user_turns: 2, request: "too_short", saved: nil))

      run_with(["/recap"])

      expect(screen.lines).to include("no recap yet: it needs at least 2 user turns")
    end

    it "says so when the worker doesn't answer" do
      allow(client).to receive(:request_recap).and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: "{}"))

      run_with(["/recap"])

      expect(screen.lines).to include("(no recap: the worker did not answer)")
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

  describe "the session's commands, from its snapshot" do
    let(:commands) do
      Samagotchi::SessionCommands.builtin_registry.listing +
        [{ "name" => "/hello", "description" => "greet", "anytime" => false, "local" => false, "uis" => nil,
           "source" => "sample-plugin" }]
    end
    let(:joined) { snapshot.tap { |frame| frame["snapshot"]["commands"] = commands } }

    before do
      allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: "{}"))
      allow(client).to receive(:post_turn).and_return(ack)
    end

    it "sends a plugin's command to the worker, and an unknown /foo to the model as a prompt" do
      run_with(["/hello again", "/foo bar"], first: joined)

      expect(client).to have_received(:post_command).once.with(line: "/hello again", client_id: "tui:1")
      expect(client).to have_received(:post_turn).once.with(prompt: "/foo bar", client_id: "tui:1")
    end

    it "hints a typo of a command and sends nothing" do
      run_with(["/modle"], first: joined)

      expect(screen.lines).to include("Unknown command /modle. Did you mean /model? /help lists the commands.")
      expect(client).not_to have_received(:post_turn)
      expect(client).not_to have_received(:post_command)
    end

    it "sends /hello there as a prompt when the snapshot doesn't name it (an older worker)" do
      run_with(["/hello there"])

      expect(client).to have_received(:post_turn).once.with(prompt: "/hello there", client_id: "tui:1")
      expect(client).not_to have_received(:post_command)
    end

    it "hints a bare /hello when the snapshot doesn't name it: one word, no command answers it" do
      run_with(["/hello"])

      expect(screen.lines).to include("Unknown command /hello. Did you mean /help? /help lists the commands.")
      expect(client).not_to have_received(:post_turn)
      expect(client).not_to have_received(:post_command)
    end

    it "completes plugin commands, with the attached TUI's own" do
      run_with([], first: joined)

      expect(attached.send(:slash_commands)).to include("/hello", "/detach", "/model")
    end
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

  it "reads the continue words at the step-limit question, Enter alone continuing, and draws no second slot or line" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    limit = { "id" => "c1", "kind" => "continue", "header" => "Step limit", "options" => %w[Continue Stop],
              "question" => "The turn ran out of iterations (3 steps) before it answered. Continue it?", "allow_freeform" => true }
    push("type" => "continue_offered", "context" => { "original_prompt" => "task" }, "no_interrupt" => false)
    push("type" => "question_requested", "pending_question" => limit)

    wait_for { screen.slots[:notes]&.any? { |line| line.include?("Step limit") } }
    expect(screen.slots[:notes].join("\n")).to include("Enter or yes = Continue")
    expect(prompts.last).to eq("? ")
    typed << ""
    wait_for { screen.lines.any? { |line| line.include?("→ Continue") } }
    # The worker's events for that answer: the old offer's slot doesn't come back, nor its own line.
    push("type" => "question_answered", "id" => "c1", "answer" => { "selected" => ["Continue"] })
    push("type" => "continue_resolved", "decision" => "resume", "client_id" => "tui:1")
    wait_for { prompts.last == "> " }
    finish

    expect(client).to have_received(:answer).with(id: "c1", selected: ["Continue"], freeform: nil)
    expect(screen.slots).not_to have_key(:notes)
    expect(screen.lines.grep(/Continue it\?/).size).to eq(1)
  end

  it "stops at the step-limit question with no, <reason>" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    push("type" => "question_requested", "pending_question" => { "id" => "c1", "kind" => "continue", "options" => %w[Continue Stop],
                                                                 "question" => "Continue it?", "allow_freeform" => true })
    wait_for { prompts.last == "? " }
    typed << "no, it is going in circles"
    wait_for { screen.lines.any? { |line| line.include?("→ Stop: it is going in circles") } }
    finish

    expect(client).to have_received(:answer).with(id: "c1", selected: ["Stop"], freeform: "it is going in circles")
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

    # A parent agent driving chi --attach (piped stdin, an agent marker):
    # its answers are a parent's, held to guardrails.parent_approvals.
    context "answered by a parent agent" do
      let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", parent_answers: true) }

      it "marks the answer as chi answer's and shows the worker's refusal, the question still open" do
        refusal = { "error" => "parent_approval_refused", "detail" => "allowing a tool call is up to the user" }
        allow(client).to receive(:answer)
          .and_return(Samagotchi::BridgeClient::Response.new(status: 403, body: JSON.generate(refusal)))
        start(first: snapshot(pending_question: approval))
        wait_for { prompts.last == "? " }
        typed << "2"
        wait_for { screen.lines.any? { |line| line.include?("allowing a tool call is up to the user") } }
        expect(prompts.last).to eq("? ")
        finish
        expect(client).to have_received(:answer).with(id: "a1", selected: ["Allow this call in this repo"], freeform: nil,
                                                      client_id: Samagotchi::Guardrails::ParentApprovals::CLIENT_ID)
      end
    end

    it "prints an edit's diff above the slot once, when the snapshot and the event both bring it" do
      allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      edit = approval.merge("question" => "edit: /k.conf\n  change: +1 \u22121",
                            "approval" => { "scopes" => %w[once], "preview" => { "text" => "@@ -1 +1 @@\n-a\n+b" } })
      start(first: snapshot(pending_question: edit))
      wait_for { prompts.last == "? " }
      push("type" => "question_requested", "pending_question" => edit)
      wait_for { screen.slots[:notes] }
      expect(screen.slots[:notes]).to include("! edit: /k.conf", "  change: +1 \u22121")
      typed << ""
      wait_for { prompts.last == "> " }
      finish
      expect(screen.lines.count("@@ -1 +1 @@\n-a\n+b")).to eq(1)
    end

    it "shows that the question waits in the parent too, live, and a relayed card's close in its own words" do
      start
      push("type" => "question_requested", "pending_question" => approval)
      wait_for { screen.slots[:notes] }
      push("type" => "question_relay", "id" => "a1", "relayed_to" => { "parent_id" => "p" * 36, "parent_short" => "pppppppp" })
      wait_for { screen.slots[:notes]&.include?("  waiting in parent pppppppp too (answering here works)") }
      push("type" => "question_relay", "id" => "a1", "relayed_to" => nil, "reason" => "parent_gone")
      wait_for { !screen.slots[:notes].to_s.include?("waiting in parent") }
      push("type" => "question_cancelled", "id" => "a1", "reason" => "user")

      relayed = approval.merge("id" => "a2", "relay" => { "child_id" => "cccc1111-0", "chain" => ["cccc1111"], "task" => "push it",
                                                          "asked" => "execute: git push" })
      push("type" => "question_requested", "pending_question" => relayed)
      wait_for { screen.slots[:notes]&.include?("  delegate cccc1111 · push it") }
      push("type" => "question_cancelled", "id" => "a2", "reason" => "answered_on_child")
      wait_for { prompts.last == "> " }
      finish
      expect(screen.lines).to include("! execute: git push → (question cancelled)",
                                      "! cccc1111: execute: git push → (answered in cccc1111)")
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

  it "keeps the question open when the worker doesn't answer the answer or the dismiss" do
    allow(client).to receive(:answer).and_raise(Errno::ETIMEDOUT.new("bridge answer: no reply within 30s"))
    allow(client).to receive(:dismiss_question).and_raise(Errno::ECONNREFUSED)
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "? " }

    typed << "1"
    wait_for { screen.lines.last.to_s.start_with?("could not answer") }
    typed << ""
    wait_for { screen.lines.last.to_s.start_with?("could not dismiss") }
    finish

    expect(screen.lines).to include("could not answer (worker not answering: no reply within 30s)",
                                    "could not dismiss the question (worker unreachable: connection refused); " \
                                    "Ctrl-C cancels the turn")
    expect(prompts.last).to eq("? ")
  end

  it "keeps the question open when the worker dropped the answer or the dismiss as too late" do
    late = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
    allow(client).to receive_messages(answer: late, dismiss_question: late)
    start(first: snapshot(pending_question: question))
    wait_for { prompts.last == "? " }

    typed << "1"
    wait_for { screen.lines.last.to_s.start_with?("could not answer") }
    typed << ""
    wait_for { screen.lines.last.to_s.start_with?("could not dismiss") }
    finish

    expect(screen.lines).to include("could not answer (worker not answering in time)",
                                    "could not dismiss the question (worker not answering in time); Ctrl-C cancels the turn")
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
    expect(screen.lines).to include("✕ turn failed: server error from host main: HTTP 500", "  prompt restored for retry")
  end

  it "leaves the input alone for a prompt it didn't send in this run (a replayed event, another UI)" do
    fail_turn("e-old")
    @push.call("type" => "prompt_restored", "prompt" => "theirs", "origin" => { "client_id" => "web:1", "enqueued_id" => "e2" })

    expect(reads.pop(timeout: 0.3)).to be_nil
    expect(screen.lines).not_to include("  prompt restored for retry")
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

  it "asks a question pending between turns (the step-limit one) on a join" do
    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    question = { id: "q9", kind: "continue", header: "Step limit", question: "The turn ran out of iterations. Continue it?",
                 options: %w[Continue Stop], multi_select: false, allow_freeform: true, status: "pending" }
    snapshot = joined.tap { |event| event[:snapshot][:pending_question] = question }
    other.handle_event(JSON.parse(JSON.generate(snapshot)))

    expect(other.send(:prompt_text)).to eq("? ")
    expect(screen.slots[:notes].join("\n")).to include("Step limit").and include("Continue")
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
      allow(Samagotchi::Log).to receive(:info).and_call_original
      old = Samagotchi::ContextNote.message(note_id: "n0", text: "old news", source: "cli")
      join_fresh([{ role: "system", content: "sys" }, old, { role: "user", content: "hi" },
                  { role: "model", content: "hello there" }, note])

      expect(screen.lines).to eq(["user> hi", "hello there", "note from slack: deploy frozen"])
      # The log counts every note the session holds, shown or not.
      expect(Samagotchi::Log).to have_received(:info).with(:attached, "joined", session: "s-1234", messages: 2, notes: 2)
    end

    it "shows the notes of a session that has no exchange yet" do
      join_fresh([{ role: "system", content: "sys" }, note])

      expect(screen.lines).to eq(["note from slack: deploy frozen"])
    end
  end

  describe "a plugin's steer" do
    let(:steer) { Samagotchi::Steer.message(text: "how is it going?", source: "check-in") }

    it "is not the prompt in the join header: the prompt, the steer's line, the answer" do
      other = described_class.new(client: client, screen: screen, client_id: "tui:2")
      messages = [{ role: "user", content: "fix it" }, { role: "model", content: "" }, steer, { role: "model", content: "fixed" }]
      other.handle_event(JSON.parse(JSON.generate(joined.tap { |event| event[:snapshot][:messages] = messages })))

      expect(screen.lines).to eq(["user> fix it", "check-in> nudged: how is it going?", "fixed"])
    end

    it "shows a running turn's steer part on join" do
      other = described_class.new(client: client, screen: screen, client_id: "tui:2")
      turn = { prompt: "go", origin: { client_id: "web:1" }, parts: [{ kind: "steer", source: "check-in", text: "status?" }] }
      other.handle_event(JSON.parse(JSON.generate(joined.merge(snapshot: joined[:snapshot].merge(current_turn: turn)))))

      expect(screen.lines).to include("check-in> nudged: status?")
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
    expect(screen.lines.last(2)).to eq(["✕ turn canceled (Ctrl-C)", "  partial progress kept; !rollback restores the pre-turn state"])

    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "tui:1" } }, { type: :turn_canceled, cancellation_reason: "ctrl_c" })
    expect(screen.lines.last).to eq("✕ turn canceled (Ctrl-C)")
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

  it "stops the launch when the worker doesn't answer the command" do
    allow(client).to receive(:post_command).and_raise(Errno::ETIMEDOUT.new("bridge command: no reply within 30s"))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/model fast")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to eq("could not switch to the --model: worker not answering: no reply within 30s")
  end

  it "stops the launch when the worker dropped the command as too late" do
    allow(client).to receive(:post_command)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}'))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/model fast")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to eq("could not switch to the --model: worker not answering in time")
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

  it "sends #name as typed, as the REPL does" do
    run_loop(["PR #1: check #notes and #project/todo"])

    expect(client).to have_received(:post_turn)
      .with(prompt: "PR #1: check #notes and #project/todo", client_id: "tui:1")
  end

  it "offers the attached commands on Tab, /quit too" do
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1")

    expect(attached.send(:assist_path_completion_candidates, "/q")).to eq(["/quit"])
    expect(attached.send(:assist_path_completion_candidates, "/mo")).to eq(%w[/model /models])
  end

  it "types the default input into a new session's first read, unless told not to" do
    ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Please "

    expect(run_loop([nil], default_input: true)).to eq(["Please "])
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

  def join(model_name: "m1", used_memory_names: [], **state)
    { type: :snapshot, snapshot: { messages: [], current_turn: nil, queued: [], event_seq: 1 },
      session_state_snapshot: { status: "idle", model_name: model_name, used_memory_names: used_memory_names, **state } }
  end

  def status = screen.slots[:status]&.first

  it "shows the REPL's segments: the worker's model and the session's memories, from the join" do
    feed(join(used_memory_names: %w[notes todo]))

    expect(status).to eq("status> model=m1 | mem: notes, todo")
  end

  it "shows the last turn's ctx from the join, before a turn of its own" do
    feed(join(used_memory_names: %w[notes], context_status: { est_pct: 7.5, bucket: "under20" }))

    expect(status).to eq("status> model=m1 | ctx=7.5% (under20) | mem: notes")
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

  it "shows the session's --memory list with the used memories, and its --mute list, from the join" do
    feed(join(preloaded_memory_names: %w[cli_usage], muted_memory_names: %w[gh-helper]))
    expect(status).to eq("status> model=m1 | mem: cli_usage | muted: gh-helper")

    # After a turn the used list carries the preloads itself; no repeats.
    feed({ type: :used_memories_updated, used_memory_names: %w[notes cli_usage] })
    expect(status).to eq("status> model=m1 | mem: notes, cli_usage | muted: gh-helper")
  end

  it "marks a delegated session with its parent's short id, from the join" do
    feed(join(parent_id: "3f2a1c9e-0000-4000-8000-000000000000", preloaded_memory_names: %w[delegated]))
    expect(status).to eq("status> model=m1 | ↳ 3f2a1c9e | mem: delegated")
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
    # The read starts on its own thread as the loop takes the snapshot in.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.01 until attached.running? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
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

    expect(client).to have_received(:follow)
      .with(client_id: "tui:1", rediscover: anything,
            reconnect_delays: Samagotchi::BridgeClient::EventStream::REDISCOVER_DELAYS)
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

  # The worker checks again once it has let go: a note arriving first keeps it.
  it "says an empty session will be discarded instead of how to resume it" do
    allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":true}'))

    run_lines("/exit")

    expect(screen.lines.last).to eq("Detached; the session is empty: it will be discarded if nothing arrives before its worker stops.")
  end

  it "says how to resume a session the worker keeps" do
    allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":false}'))

    run_lines("/exit")

    expect(screen.lines.last).to eq("Detached; the session's worker is stopping. Resume with: chi --resume s-1234")
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

  it "says the worker didn't answer in time when the Bridge read the exit too late" do
    allow(client).to receive(:request_exit).and_return(response(408, '{"error":"deadline_passed"}'))

    expect(run_lines("/exit")).to eq(:detached)

    expect(screen.lines.last)
      .to eq("Detached (could not ask the worker to stop: worker not answering in time). Re-attach with: chi --attach s-1234")
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

    ["/exit --delete", "/quit --delete", "exit --delete", "EXIT --DELETE"].each do |line|
      it "asks the worker to exit, then deletes the session (#{line})" do
        allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

        expect(run_lines(line)).to eq(:detached)

        expect(client).to have_received(:request_exit).with(client_id: "tui:1", delete: true)
        expect(deleted).to eq(["s-1234"])
        expect(screen.lines.last).to eq("Detached; deleted session s-1234.")
      end
    end

    it "leaves an empty session to the worker, which deletes it as it leaves" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":true}'))

      run_lines("/exit --delete")

      expect(deleted).to be_empty
      expect(screen.lines.last).to eq("Detached; the session is empty: it will be discarded if nothing arrives before its worker stops.")
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

  describe "/archive" do
    let(:archived) { [] }
    let(:archive_session) do
      lambda do |id|
        archived << id
        { id: id, archived: [id], stopped: [], discarded: [] }
      end
    end
    let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", archive_session: archive_session) }

    it "asks the worker to exit, then archives the session" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

      expect(run_lines("/archive")).to eq(:detached)

      expect(client).to have_received(:request_exit).with(client_id: "tui:1")
      expect(archived).to eq(["s-1234"])
      expect(screen.lines.last).to eq("Detached; archived session s-1234. chi sessions list --archived finds it.")
    end

    it "leaves an empty session to the worker, which discards it as it leaves" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":true}'))

      run_lines("/archive")

      expect(archived).to be_empty
      expect(screen.lines.last).to eq("Detached; the session is empty: it will be discarded if nothing arrives before its worker stops.")
    end

    it "archives when the worker stays up for another UI: the archive stops it, as the web's does" do
      allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"client_connected"}'))

      run_lines("/archive")

      expect(archived).to eq(["s-1234"])
      expect(screen.lines.last).to start_with("Detached; archived session s-1234.")
    end

    it "says so when the archive is refused (a turn running)" do
      allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"turn_running"}'))
      refusing = ->(id) { raise Samagotchi::SessionManager::ArchiveRefused.new(id, :busy) }
      loop_ui = described_class.new(client: client, screen: screen, client_id: "tui:1", archive_session: refusing)
      allow(client).to receive(:follow) do |**, &block|
        block.call("type" => "snapshot", "snapshot" => idle)
        stream
      end

      loop_ui.run(input: ->(_prompt, _prefill) { "/archive" })

      expect(screen.lines.last).to eq("Detached; session s-1234 was not archived (a turn is running; wait for it or " \
                                      "cancel it first). Re-attach with: chi --attach s-1234")
    end

    it "archives nothing when the exit request fails" do
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)

      run_lines("/archive")

      expect(archived).to be_empty
      expect(screen.lines.last).to end_with("Not archived.")
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

  it "runs /stats and /recap at a continue offer, the offer staying open" do
    allow(client).to receive(:post_command)
    allow(client).to receive(:get_json).with("stats")
      .and_return(JSON.parse(JSON.generate(metrics: { turns: 3 })))
    allow(client).to receive(:request_recap)
      .and_return(response(200, JSON.generate(enabled: false)))
    offered = idle.merge("continue_offer" => { "context" => {}, "no_interrupt" => false })

    expect(run_lines("/stats", "/recap", nil, snapshot: offered, at: "? ")).to eq(:detached)

    expect(client).not_to have_received(:post_command)
    expect(screen.lines).to include(a_string_including("turns:            3"),
                                    a_string_starting_with("recap is off"))
    expect(attached.instance_variable_get(:@continue_offer)).not_to be_nil
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

  it "detaches on /detach at an open question, as Ctrl-D does; the question stays open for another UI" do
    allow(client).to receive(:answer)
    allow(client).to receive(:dismiss_question)
    question = { "id" => "q1", "question" => "Pick", "options" => %w[a b] }
    turn = { "prompt" => "p", "parts" => [], "pending_question" => question }

    expect(run_lines("/detach", snapshot: idle.merge("current_turn" => turn), at: "? ")).to eq(:detached)

    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --attach s-1234")
    expect(client).not_to have_received(:answer)
    expect(client).not_to have_received(:dismiss_question)
  end

  it "offers /detach and /quit on Tab" do
    expect(attached.send(:assist_path_completion_candidates, "/d")).to eq(["/detach"])
    expect(attached.send(:assist_path_completion_candidates, "/q")).to eq(["/quit"])
  end
end

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
    @thread = Thread.new { attached.run(input: ->(_prompt, _prefill) { ended << true && nil }) }
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
               "level" => "info", "between_turns" => true)
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
