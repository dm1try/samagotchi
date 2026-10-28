# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop do
  include WorkerLinks

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
      found = instance_double(Samagotchi::BridgeClient, session_id: "s-1234", port: 4321, host: "127.0.0.1")
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link({ port: 4321 }, client: found))
      allow(Samagotchi::Session).to receive(:stopped_marker?).and_return(false)
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
      found = instance_double(Samagotchi::BridgeClient, session_id: "s-1234", port: 4321, host: "127.0.0.1")
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(client: found))
      allow(Samagotchi::Session).to receive(:stopped_marker?)
        .with("s-1234", state_dir: Samagotchi::Session.default_state_dir).and_return(false)
      expect(attached.send(:live_worker)).to eq([found, nil])
      expect(Samagotchi::WorkerLink).to have_received(:resolve)
        .with(Samagotchi::Session.session_dir("s-1234"), unlink: true)

      allow(Samagotchi::Session).to receive(:stopped_marker?)
        .with("s-1234", state_dir: Samagotchi::Session.default_state_dir).and_return(true)
      expect(attached.send(:live_worker)).to eq([:gone, "stopped"])
      # The stream closes with that reason; here the line reads as it always has.
      attached.handle_event({ "type" => "stream_closed", "reason" => "stopped" })
      expect(screen.lines.last).to eq("Lost the session's worker (unreachable). Resume it with: chi --shared --resume s-1234")
    end

    it "says what to restart when the worker asks for a secret this terminal doesn't send" do
      attached.handle_event({ "type" => "stream_closed", "reason" => "bridge_secret" })
      expect(screen.lines.last).to eq("Lost the session's worker: #{Samagotchi::BridgeSecret.refused("s-1234")}")
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

    it "resyncs this terminal's queued ids from each snapshot" do
      attached.instance_variable_set(:@my_queued, %w[e1 stale])
      feed(snapshot(queued: [
        { enqueued_id: "e0", client_id: "tui:1", prompt: "older" },
        { enqueued_id: "e1", client_id: "tui:1", prompt: "current" },
        { enqueued_id: "other", client_id: "web:1", prompt: "theirs" }
      ]))

      expect(attached.instance_variable_get(:@my_queued)).to eq(%w[e0 e1])

      feed(snapshot(type: :reset, queued: [{ enqueued_id: "e1", prompt: "current" }]))

      expect(attached.instance_variable_get(:@my_queued)).to eq(["e1"])
    end

    it "shows a join during a hold as the live view does: thinking on the new step, not the last one's text" do
      turn = { prompt: "go", origin: nil,
               parts: [{ kind: "generation", iteration: 1 }, { kind: "text", iteration: 1, text: "Checking." },
                       { kind: "tool", iteration: 1, call_index: 0, tool: "read", params: "path=log", status: "ok" },
                       { kind: "generation", iteration: 2 }] }
      feed(snapshot(current_turn: turn))

      expect(screen.statuses.last).to eq("| thinking…")
    end

    it "adds an edit's +N −M to its tool line on a join" do
      turn = { prompt: "go", origin: nil,
               parts: [{ kind: "tool", tool: "edit", params: "path=k", status: "ok", diff: { text: "x", added: 3, removed: 1 } }] }
      feed(snapshot(current_turn: turn))
      expect(screen.lines).to include("tool> edit path=k: ok +3 \u22121")
    end

    it "marks a cut tool output on its replayed row, as the live one did" do
      turn = { prompt: "go", origin: nil,
               parts: [{ kind: "tool", tool: "read", params: "path=big", status: "ok", output_truncated: true, action: "reading file" },
                       { kind: "tool", tool: "read", params: "path=old", status: "ok", output_truncated: true },
                       { kind: "tool", tool: "read", params: "path=small", status: "ok", output_truncated: false }] }
      feed(snapshot(current_turn: turn))

      expect(screen.lines).to include("tool> reading file (read path=big): ok [cut]",
                                      "tool> read path=old: ok [cut]",
                                      "tool> read path=small: ok")
    end

    it "does not repeat the joined turn's earlier tools in its summary" do
      activity = { action: "reading file", tool: "read", params: "path=log", status: "ok" }
      turn = { prompt: "go", origin: nil, parts: [{ kind: "tool", tool: "read", params: "path=log", status: "ok" }] }
      feed(snapshot(current_turn: turn), { type: :turn_completed, turn_summary: summary("done", tool_activity: [activity]) })

      expect(screen.lines).to eq(["user> go", "tool> read path=log: ok", "done"])
      expect(attached).not_to be_running
    end

    it "renders a call-less started event and a result-less completed event" do
      feed({ type: :turn_started, prompt: "write it", origin: { client_id: "tui:1" } },
           { type: :tool_call_started, iteration: 1, call_index: 1, tool: "write", params: "path=out.txt" },
           { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "write", duration_ms: 5,
             activity: { tool: "write", params: "path=out.txt", status: "ok" }, output: "written" },
           { type: :turn_completed, turn_summary: summary("done") })

      expect(screen.lines.first).to include("(write path=out.txt): ok")
      expect(screen.lines.last).to eq("done")
    end

    # Shared with the web: spec/shared/turn_snapshot.json.
    it "replays the joined turn as it was drawn live: tool rows with their action and duration" do
      fixture = JSON.parse(File.read(File.expand_path("../shared/turn_snapshot.json", __dir__)))
      joined = snapshot(current_turn: fixture.dig("snapshot", "current_turn"), queued: fixture.dig("snapshot", "queued"))
      feed(joined)

      expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }).to eq([
        "web> do it",
        # The described command: its description in place of the params.
        "tool> Running command (execute: List the files): ok (1.3s)",
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

    it "reads a saved tool row's status as the live row did, without the [tool] lead or a ran-as line" do
      handed_over = "[execute]\nStill running at the 120s limit: moved to a background task, not killed.\n" \
                    "task_id: t1\nWait for it with task_wait (it may take minutes); task_stop stops it.\n" \
                    "stdout (so far, tail):\nexit: 1"
      feed(snapshot(messages: [
        { role: "user", content: "go" },
        { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "true" } }] },
        { role: "tool_response", tool_call_id: "c1", content: handed_over },
        { role: "model", content: "", tool_calls: [{ id: "c2", name: "execute", arguments: { command: "true" } }] },
        { role: "tool_response", tool_call_id: "c2", content: "[execute]\nError: cwd not found: /nope" },
        { role: "model", content: "", tool_calls: [{ id: "c3", name: "execute", arguments: { command: "true" } }] },
        { role: "tool_response", tool_call_id: "c3",
          content: "ran as: execute command=\"true\"\n[execute]\nError: cwd not found: /nope" },
        { role: "model", content: "", tool_calls: [{ id: "c4", name: "execute", arguments: { command: "true" } }] },
        { role: "tool_response", tool_call_id: "c4",
          content: "ran as: execute command=\"true\"\n[execute]\nstdout:\nx\n\nexit: 3" },
        { role: "model", content: "", tool_calls: [{ id: "c5", name: "execute", arguments: { command: "true" } }] },
        { role: "tool_response", tool_call_id: "c5",
          content: "ran as: execute command=\"true\"\n[execute]\nstdout:\nx\n\nexit: 0" },
        { role: "model", content: "Done." }
      ]))

      expect(screen.lines.first).to eq("user> go")
      expect(screen.lines[1]).to end_with(": ok")
      expect(screen.lines[2]).to end_with(": error")
      expect(screen.lines[3]).to end_with(": error")
      expect(screen.lines[4]).to end_with(": error")
      expect(screen.lines[5]).to end_with(": ok")
      expect(screen.lines.last).to eq("Done.")
    end

    it "shows a saved grep that found nothing as done, a real exit 1 as an error" do
      feed(snapshot(messages: [{ role: "user", content: "find it" },
                               { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "rg zzz lib/" } }] },
                               { role: "tool_response", tool_call_id: "c1", content: "exit: 1 (no output)" },
                               { role: "model", content: "", tool_calls: [{ id: "c2", name: "execute", arguments: { command: "sed -n 1p f" } }] },
                               { role: "tool_response", tool_call_id: "c2", content: "exit: 1 (no output)" },
                               { role: "model", content: "Done." }]))

      expect(screen.lines).to eq(["user> find it", 'tool> running command (execute command="rg zzz lib/"): ok',
                                  'tool> running command (execute command="sed -n 1p f"): error', "Done."])
    end

    it "shows a saved command's description in its tool row, as the live row did" do
      feed(snapshot(messages: [{ role: "user", content: "go" },
                               { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute",
                                                                            arguments: { command: "ls && pwd", description: "Look around." } }] },
                               { role: "tool_response", tool_call_id: "c1", content: "exit: 0" },
                               { role: "model", content: "Done." }]))

      expect(screen.lines).to eq(["user> go", "tool> running command (execute: Look around): ok", "Done."])
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

      it "marks a replayed row System 1 allowed once, from its saved record" do
        save_records([{ turn_id: "t1", iteration: 1, call_index: 1, tool: "execute", duration_ms: 1234,
                        guardrail: { rule: "git-push", p: 0.96 } },
                      { turn_id: "t1", iteration: 2, call_index: 1, tool: "read", duration_ms: 42 }])
        feed(snapshot(messages: messages))

        expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") })
          .to eq(["user> find it", 'tool> running command (execute command="true"): ok (1.2s) · auto-allowed (System 1, p=0.96)',
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

    # The web sends "[image: name]" as an image-only turn's text: the
    # prompt line names the image already, as the recap does it.
    it "names an image-only turn's image once" do
      image = { file: "images/0123456789abcdef.png", mime: "image/png", width: 1280, height: 800, name: "shot.png" }
      feed(snapshot(messages: [{ role: "user", content: "[image: shot.png]", images: [image] }, { role: "model", content: "A cat." }]))

      expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }).to eq(["user> [image: shot.png]", "A cat."])
    end

    it "still shows the image lines of a turn with words" do
      image = { file: "images/0123456789abcdef.png", mime: "image/png", width: 1280, height: 800, name: "shot.png" }
      feed(snapshot(messages: [{ role: "user", content: "what is it?", images: [image] }, { role: "model", content: "A cat." }]))

      expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") })
        .to eq(["user> what is it?", "[image shot.png 1280×800 · ~1.3k tokens]", "A cat."])
    end

    context "with the session's saved turn record" do
      def save_analytics(turn_records: [], tool_records: [])
        dir = Samagotchi::Session.session_dir("s-1234")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "analytics.json"),
                   JSON.generate("turn_records" => turn_records, "tool_records" => tool_records))
      end

      # The ✕ and the hint are painted; compare the words (as the neighbour specs).
      def plain_lines = screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }

      # The last turn failed with its steps kept: its own record, and the
      # step text a failed turn must not show as its answer.
      let(:messages) do
        [{ role: "user", content: "find it", turn_id: "t1" },
         { role: "model", content: "Searching.", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "true" } }] },
         { role: "tool_response", tool_call_id: "c1", content: "exit: 0" },
         { role: "model", content: "Still searching." }]
      end

      after { FileUtils.rm_rf(Samagotchi::Session.session_dir("s-1234")) }

      it "draws a failed turn's line and the kept-progress hint after its steps, as live" do
        save_analytics(turn_records: [{ "id" => "t1", "status" => "failed", "duration_ms" => 2000,
                                        "failure" => { "summary" => "HTTP 500: boom", "kept_steps" => 1 } }])
        feed(snapshot(messages: messages))

        expect(plain_lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                   "✕ turn failed: HTTP 500: boom · 2.0s",
                                   "  #{Samagotchi::TerminalUI::Formatting::ROLLBACK_HINT}"])
      end

      it "draws a failed turn's message without the hint when its steps didn't stay" do
        save_analytics(turn_records: [{ "id" => "t1", "status" => "failed", "duration_ms" => 1500,
                                        "failure" => { "message" => "bad image", "error_class" => "ArgumentError" } }])
        feed(snapshot(messages: messages))

        expect(plain_lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                   "✕ turn failed: bad image · 1.5s"])
      end

      it "draws a stopped turn's line and the hint after its steps, not the text it streamed before the stop" do
        save_analytics(turn_records: [{ "id" => "t1", "status" => "canceled", "duration_ms" => 3100,
                                        "cancellation_reason" => "session_stopped", "continue" => false }])
        feed(snapshot(messages: [*messages.take(3), { role: "model", content: "Still search", interrupted: true }]))

        expect(plain_lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                   "■ turn canceled (session stopped) · 3.1s",
                                   "  #{Samagotchi::TerminalUI::Formatting::ROLLBACK_HINT}"])
      end

      it "draws a turn a hook stopped by its stopper, without the hint for a continue" do
        save_analytics(turn_records: [{ "id" => "t1", "status" => "canceled", "duration_ms" => 1000,
                                        "cancellation_reason" => "hook", "cancelled_by" => "loop-guard", "continue" => true }])
        feed(snapshot(messages: messages))

        expect(plain_lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                   "■ turn stopped by loop-guard · 1.0s"])
      end

      it "leaves a failed record saved before the failure field as it was" do
        save_analytics(turn_records: [{ "id" => "t1", "status" => "failed", "duration_ms" => 2000 }])
        feed(snapshot(messages: messages))

        expect(plain_lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                   "Still searching."])
      end

      describe "a guardrail-denied call" do
        let(:messages) do
          [{ role: "user", content: "clean up", turn_id: "t1" },
           { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "rm -rf build" } }] },
           { role: "tool_response", tool_call_id: "c1", content: "[execute] Error: denied by guardrail (rm): not here" },
           { role: "model", content: "It was denied." }]
        end

        # The web reloads it from the same record: blocked, as live.
        it "takes its status from the saved tool record" do
          save_analytics(tool_records: [{ "turn_id" => "t1", "iteration" => 1, "call_index" => 1, "tool" => "execute",
                                          "status" => "blocked", "duration_ms" => 1200 }])
          feed(snapshot(messages: messages))

          expect(plain_lines).to eq(["user> clean up", 'tool> running command (execute command="rm -rf build"): blocked (1.2s)',
                                     "It was denied."])
        end

        it "reads it from the saved text when the session has no record of it: blocked too" do
          feed(snapshot(messages: messages))

          expect(plain_lines).to eq(["user> clean up", 'tool> running command (execute command="rm -rf build"): blocked',
                                     "It was denied."])
        end
      end

      it "leaves a completed turn's answer as it was" do
        save_analytics(turn_records: [{ "id" => "t1", "status" => "completed", "duration_ms" => 2000 }])
        feed(snapshot(messages: messages))

        expect(plain_lines).to eq(["user> find it", 'tool> running command (execute command="true"): ok',
                                   "Still searching."])
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
end
