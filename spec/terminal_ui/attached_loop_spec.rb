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

    describe "a turn's images" do
      let(:image) { { file: "images/0123456789abcdef.png", mime: "image/png", width: 1280, height: 800, name: "shot.png" } }
      let(:image_line) { "[image shot.png 1280×800 · ~1.3k tokens]" }

      def plain_lines = screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }

      # The web sends "[image: name]" as an image-only turn's text: its
      # prompt line names the image already.
      it "names another client's image-only turn once" do
        feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "web:tab1", prompt: "[image: shot.png]" },
             { type: :turn_started, prompt: "[image: shot.png]", origin: { client_id: "web:tab1", enqueued_id: "e1" },
               images: [image] })

        expect(plain_lines).to eq(["web> [image: shot.png]"])
      end

      it "names an unannounced image-only turn once" do
        feed({ type: :turn_started, prompt: "[image: shot.png]", origin: { client_id: "web:tab1" }, images: [image] })

        expect(plain_lines).to eq(["web> [image: shot.png]"])
      end

      it "names a joined running image-only turn once" do
        screen.lines.clear
        turn = { prompt: "[image: shot.png]", origin: { client_id: "web:tab1" }, parts: [], images: [image] }
        feed(snapshot(current_turn: turn, type: :reset))

        expect(plain_lines).to include("web> [image: shot.png]")
        expect(plain_lines).not_to include(image_line)
      end

      it "still shows the image lines of another client's turn with words" do
        feed({ type: :turn_started, prompt: "what is it?", origin: { client_id: "web:tab1" }, images: [image] })

        expect(plain_lines).to eq(["web> what is it?", image_line])
      end

      # The own-send echo already names an image-only prompt.
      it "does not repeat the images of its own image-only turn" do
        feed({ type: :turn_started, prompt: "[image: shot.png]", origin: { client_id: "tui:1", enqueued_id: "e1" },
               images: [image] })

        expect(plain_lines).to be_empty
      end

      it "does not repeat its echoed image-only prompt when the turn starts" do
        allow(client).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: "{}"))
        own_send = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "[image: shot.png]")
        own_send.handle_event(JSON.parse(JSON.generate(snapshot)))
        own_send.handle_event(JSON.parse(JSON.generate(
          type: :turn_started, prompt: "[image: shot.png]", origin: { client_id: "tui:1" }, images: [image]
        )))

        expect(plain_lines).to eq(["> [image: shot.png]"])
      end
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

      expect(screen.lines.last(2)).to eq(["■ turn canceled (Ctrl-C) · 3.1s", "  #{Samagotchi::TerminalUI::Formatting::ROLLBACK_HINT}"])
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

  describe "the time between activity" do
    # Local times: one zone, so a 47-minute gap stays on one local day.
    around { |example| with_env("TZ" => "Europe/Berlin") { example.run } }

    let(:wall) { [Time.utc(2026, 10, 24, 14, 0, 0)] }
    let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", now: -> { wall.first }) }

    def pass(minutes) = wall[0] += minutes * 60
    def clock_of(time) = time.localtime.strftime("%H:%M")
    def stamp(minutes_ago) = (wall.first - (minutes_ago * 60)).iso8601(3)
    def dividers = screen.lines.grep(/──/)

    def web_turn(prompt)
      feed({ type: :turn_started, prompt: prompt, origin: { client_id: "web:tab1" } },
           { type: :turn_completed, turn_summary: summary("ok") })
    end

    it "marks a quiet gap of 10 minutes or more before another client's prompt, from the end of the last turn" do
      feed(snapshot)
      web_turn("first")
      pass(15)
      web_turn("second")

      expect(dividers).to eq(["── #{clock_of(wall.first)} · 15 min later ──"])
      expect(screen.lines.index(dividers.first)).to eq(screen.lines.index("web> second") - 1)
    end

    it "marks nothing after a short pause, nor inside a long turn" do
      feed(snapshot)
      web_turn("first")
      pass(2)
      feed({ type: :turn_started, prompt: "second", origin: { client_id: "web:tab1" } })
      pass(30)
      feed({ type: :reminder_injected, reminders: ["heartbeat"] }, { type: :turn_completed, turn_summary: summary("ok") })

      expect(dividers).to be_empty
    end

    it "marks a gap before a reminder, a context note and a recap between turns, the recap with its time" do
      feed(snapshot)
      web_turn("first")
      pass(11)
      feed({ type: :context_added, label: "slack", text: "deploy frozen" })
      pass(12)
      created = wall.first.utc.iso8601
      feed({ type: :recap_ready, recap: "We fixed the bug.", created_at: created })

      expect(dividers.size).to eq(2)
      expect(screen.lines.last(2)).to eq(["── #{clock_of(wall.first)} · 12 min later ──",
                                          "recap #{clock_of(wall.first)}> We fixed the bug."])
    end

    it "says when the last activity was after the join block, and marks no second gap at the next prompt" do
      joined = snapshot(messages: [{ role: "user", content: "hi", at: stamp(48) }, { role: "model", content: "hello", at: stamp(47) }])
      joined[:snapshot][:saved_recap] = { text: "We said hi.", covered: 2, turns_since: 0, created_at: stamp(45) }
      feed(joined)
      web_turn("back")

      last = wall.first - (47 * 60)
      expect(screen.lines.first(4)).to eq(["recap #{clock_of(wall.first - (45 * 60))}> We said hi.", "user> hi", "hello",
                                           "── last activity #{clock_of(last)} · 47 min ago ──"])
      expect(dividers.size).to eq(1)
    end

    it "names the day of a last activity on another day, and falls back to the saved recap's time" do
      joined = snapshot(messages: [{ role: "user", content: "hi" }])
      joined[:snapshot][:saved_recap] = { text: "We said hi.", covered: 1, turns_since: 0, created_at: stamp(26 * 60) }
      feed(joined)

      last = (wall.first - (26 * 3600)).localtime
      expect(dividers).to eq(["── last activity #{last.strftime("%a %-d %b %H:%M")} · 1 d ago ──"])
    end

    it "prints no join line after a short pause or while a turn runs, but the next prompt still marks the gap" do
      feed(snapshot(messages: [{ role: "user", content: "hi", at: stamp(5) }, { role: "model", content: "hello", at: stamp(4) }]))
      expect(dividers).to be_empty

      pass(8)
      web_turn("later")
      expect(dividers).to eq(["── #{clock_of(wall.first)} · 12 min later ──"])
    end

    it "puts the divider of a typed prompt above its echo, once, and none for a command or a steer" do
      feed(snapshot)
      web_turn("first")
      pass(20)
      expect(attached.send(:gap_above_echo, "/stats")).to be_nil
      expect(attached.send(:gap_above_echo, "fix it")).to eq("── #{clock_of(wall.first)} · 20 min later ──")
      feed({ type: :turn_started, prompt: "fix it", origin: { client_id: "tui:1" } })
      pass(20)
      expect(attached.send(:gap_above_echo, "and this")).to be_nil

      expect(dividers).to be_empty
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

  it "shows a hook's notice, live and from a snapshot's turn parts, one marked fallback_for too" do
    feed({ type: :hook_notice, hook: "known_names.rb (bundle known-names)", text: "rejected execute", level: "info" })
    expect(screen.lines.last).to eq("known-names> rejected execute")
    feed({ type: :hook_notice, hook: "s.rb (bundle source-links)", text: "sources: JIRA-1", level: "info", fallback_for: "display" })
    expect(screen.lines.last).to eq("source-links> sources: JIRA-1")

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
      { kind: "notice", event: { type: "empty_answer_retry", iteration: 2, attempt: 1, of: 1, stopped_by: "loop-guard" } },
      { kind: "notice", event: { type: "steer_cut", iteration: 3, source: "parent_agent" } },
      { kind: "notice", event: { type: "llm_context_edited", moment: "request", text: "✂ stubbed 1 stale read · frees ~1.0k tokens" } }
    ] }
    feed(snapshot(current_turn: turn))

    plain = screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") }
    first = plain.index("↻ empty answer, asking again (1/1)")
    cut = plain.index("↻ cut by loop-guard, asking again (1/1)")
    expect(first).not_to be_nil
    expect(cut).to be > first
    expect(plain[(first + 1)...cut].join("\n")).to include("read")
    expect(plain.join("\n")).not_to include("Which?")
    expect(plain.index("↪ cut in for the parent agent's message")).to be > cut
    expect(plain.index("✂ stubbed 1 stale read · frees ~1.0k tokens")).to be > plain.index("↪ cut in for the parent agent's message")
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

    it "says a command the worker's older chi doesn't have needs a restart" do
      reply = Samagotchi::BridgeClient::Response.new(status: 400, body: '{"error":"unknown_command","detail":"not a session command"}')
      allow(client).to receive(:post_command).and_return(reply)

      expect(run_with(["/llm-context strategy stale", nil])).to eq(:detached)

      expect(screen.lines).to include(start_with("this session's worker runs an older chi and can't run /llm-context; restart it:"))
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

  it "shows the worker's per-model rows in /stats (JSON keys)" do
    rows = [{ model_ref: "a:one", started_at: "2026-10-17T10:00:00.000Z", ended_at: "2026-10-17T10:05:00.000Z", turns: 1,
              prompt_sum: 10, completion_sum: 5, prefill_tokens: 0 },
            { model_ref: "b:two", started_at: "2026-10-17T10:06:00.000Z", ended_at: nil, turns: 1, prompt_sum: 300,
              completion_sum: 7, prefill_tokens: 290 }]
    metrics = { turns: 2, tokens: { prompt_sum: 310, completion_sum: 12, source: "server" }, model_segments: rows }
    allow(client).to receive(:get_json).with("stats").and_return(JSON.parse(JSON.generate(metrics: metrics)))

    run_with(["/stats"])

    expect(screen.lines).to include(a_string_matching(%r{^models: +a:one +\S+ +1 turn +10 in / 5 out}).and(match(%r{^ +b:two +\S+now +1 turn +300 in / 7 out})),
                                    a_string_including("└ switch prefill 290 uncached prompt"))
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

    it "says when this session's own setting turned it off" do
      allow(client).to receive(:request_recap).and_return(recap_reply(enabled: false, session_off: true))

      run_with(["/recap"])

      expect(screen.lines).to include(a_string_starting_with("recap is off for this session (/recap on"))
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

    ["/model x", "/models", "/continue", "!rollback", "!ls"].each do |line|
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

  it "shows the session's title from the join and follows /title from any client" do
    feed(join(title: "Coordinator"))
    expect(status).to eq("status> Coordinator | model=m1")

    feed({ type: :command_ran, command_id: "c", client_id: "cli:send", line: "/title Release", status: "ok",
           output: "title: Release", changed: ["title"], title: "Release", model_name: "m1" })
    expect(status).to eq("status> Release | model=m1")

    feed({ type: :command_ran, command_id: "d", client_id: "web:1", line: "/title --clear", status: "ok",
           output: "title: none", changed: ["title"], title: nil, model_name: "m1" })
    expect(status).to eq("status> model=m1")
  end

  it "keeps the title through a command that didn't change it" do
    feed(join(title: "Coordinator"))
    feed({ type: :command_ran, command_id: "c", client_id: "web:1", line: "/title", status: "ok",
           output: "title: Coordinator", changed: [], model_name: "m1" })

    expect(status).to eq("status> Coordinator | model=m1")
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

  it "trails the steer hint while a turn runs, and drops it when the turn ends" do
    hint = " · typing goes in at the next step (/cut, /queue)"
    feed(join, { type: :turn_started, prompt: "p", origin: { client_id: "web:1" } })
    expect(status).to eq("status> model=m1#{hint}")

    feed({ type: :turn_completed, origin: { client_id: "web:1" } })
    expect(status).to eq("status> model=m1")

    feed({ type: :turn_started, prompt: "q", origin: { client_id: "web:1" } }, { type: :turn_canceled })
    expect(status).to eq("status> model=m1")

    feed({ type: :turn_started, prompt: "r", origin: { client_id: "web:1" } }, { type: :turn_failed, error: "boom" })
    expect(status).to eq("status> model=m1")
  end

  it "shows the steer hint when it joins a running turn" do
    feed(join.tap { |event| event[:snapshot][:current_turn] = { prompt: "go", parts: [] } })

    expect(status).to eq("status> model=m1 · typing goes in at the next step (/cut, /queue)")
  end

  describe "the children segment" do
    let(:counts) { [] }
    let(:asked) { [] }
    let(:attached) do
      described_class.new(client: client, screen: screen, client_id: "tui:1", children_counts: lambda { |id|
        asked << id
        running, waiting = counts.first
        Samagotchi::ChildrenStatus::Counts.new(running: running, waiting: waiting, unreported: 0)
      })
    end

    it "counts the delegates at the join" do
      counts << [2, 1]
      feed(join)

      expect(status).to eq("status> model=m1 | ⑂ 2 running · 1 waiting")
      expect(asked).to eq(["s-1234"])
    end

    it "counts them again when a turn ends, completed or canceled" do
      counts << [2, 0]
      feed(join)
      counts.replace([[1, 0]])
      feed({ type: :turn_started, prompt: "go", origin: { client_id: "web:1" } },
           { type: :turn_completed, turn_summary: { tool_activity: [], output: "done", resumable: false } })
      expect(status).to eq("status> model=m1 | ⑂ 1 running")

      counts.replace([[0, 0]])
      feed({ type: :turn_started, prompt: "go", origin: { client_id: "web:1" } },
           { type: :turn_canceled, cancellation_reason: "ctrl_c" })
      expect(status).to eq("status> model=m1")
      expect(asked.size).to eq(3)
    end

    it "counts them again when a delegate's report merges into the turn, not on another merge" do
      counts << [2, 0]
      feed(join)
      counts.replace([[1, 0]])
      feed({ type: :input_merged, count: 1, origins: [{ client_id: "web:a" }] })
      expect(status).to eq("status> model=m1 | ⑂ 2 running")

      feed({ type: :input_merged, count: 2, origins: [{ client_id: "web:a" }, { client_id: "child:3f2a1c9e" }] })
      expect(status).to eq("status> model=m1 | ⑂ 1 running")
      expect(asked.size).to eq(2)
    end

    it "asks for nothing with SAMAGOTCHI_STATUS_LINE=off" do
      ENV["SAMAGOTCHI_STATUS_LINE"] = "off"
      feed(join, { type: :turn_completed, turn_summary: { tool_activity: [], output: "done", resumable: false } })

      expect(asked).to be_empty
    end

    it "keeps the row when the counts can't be read" do
      broken = described_class.new(client: client, screen: screen, client_id: "tui:1",
                                   children_counts: ->(_id) { raise Errno::EACCES, "delegates.json" })
      broken.handle_event(JSON.parse(JSON.generate(join)))

      expect(status).to eq("status> model=m1")
    end
  end

  it "draws none with SAMAGOTCHI_STATUS_LINE=off" do
    ENV["SAMAGOTCHI_STATUS_LINE"] = "off"

    feed(join)

    expect(screen.slots).not_to have_key(:status)
  end
end
