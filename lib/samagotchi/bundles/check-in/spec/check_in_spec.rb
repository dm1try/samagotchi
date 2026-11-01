# frozen_string_literal: true

require "samagotchi/testing/rspec"

# The check-in plugin on its own, through the bundle test kit (docs/plugins.md,
# "Testing a bundle"); spec/samagotchi/plugin/check_in_bundle_spec.rb installs it
# and runs real turns.
RSpec.describe "The check-in plugin", :bundle do
  # The plugin as chi loads it, for session s1. Each call is a new load (a
  # worker's restart): the same sandbox, so the same data dir. Its progress
  # judgment is off here, as it is in chi until the user sets a mode.
  def plugin(settings = {})
    shipped_bundle("check-in", settings: settings, host: { session_id: "s1" })
      .tap { |bundle| bundle.judgments.mode("progress", "off") }
  end

  def fire(p, type, **event) = p.fire(type, **event)

  def turn(p) = fire(p, :before_turn, prompt: "go")

  def tools(p, *names)
    names.each { |name| fire(p, :after_tool_call, tool: name, output: "x") }
  end

  def checkin(p, args = "") = p.command("/checkin #{args}")

  def notices(p) = p.notices.map { |notice| [notice.text, notice.level] }

  def steers(p) = p.steers.map(&:text)

  it "is an anytime command" do
    expect(plugin.bundle_commands.map { |entry| [entry.name, entry.anytime] }).to eq([["/checkin", true]])
  end

  describe "mode ask (the default)" do
    it "shows one card at `after` calls, updated in place at every `every` more, with the three actions" do
      p = plugin("after" => 3, "every" => 2)
      turn(p)
      tools(p, "read", "read")
      expect(p.cards).to be_empty

      tools(p, "execute")
      tools(p, "read", "grep")

      expect(p.cards.size).to eq(2)
      first, second = p.cards
      expect(first[:title]).to eq("3 tool calls, no answer yet")
      expect(second[:title]).to eq("5 tool calls, no answer yet")
      expect(second[:id]).to eq(first[:id])
      expect(second[:body]).to match(/\A\d+s in this turn\. Last tools: read, read, execute, read, grep\.\z/)
      expect(second[:actions]).to eq([{ label: "Nudge", command: "/checkin nudge" },
                                      { label: "Keep going", command: "/checkin later" },
                                      { label: "Stop", command: "/checkin stop" }])
      expect(p.steers).to be_empty
    end

    it "doesn't count ignore_tools (task_wait, task_get, delegate_result by default)" do
      p = plugin("after" => 2)
      turn(p)
      tools(p, "task_wait", "task_get", "delegate_result", "read")
      expect(p.cards).to be_empty

      p2 = plugin("after" => 2, "ignore_tools" => ["read"])
      turn(p2)
      tools(p2, "read", "read", "task_wait", "task_wait")
      expect(p2.cards.size).to eq(1)
    end

    it "replaces the open card with one without actions when the turn ends" do
      p = plugin("after" => 1)
      turn(p)
      tools(p, "read")
      fire(p, :after_turn, status: "completed")

      closed = p.cards.last
      expect(closed).to include(id: p.cards.first[:id], title: "check-in", body: "The turn ended after 1 tool calls.")
      expect(closed[:actions]).to eq([])
    end

    it "closes a card a failed turn left open at the next before_turn, and starts counting from zero" do
      p = plugin("after" => 2)
      turn(p)
      tools(p, "read", "read")
      turn(p)

      expect(p.cards.last).to include(title: "check-in", body: "The turn ended after 2 tool calls.")
      tools(p, "read")
      expect(p.cards.size).to eq(2)
      expect(checkin(p)).to end_with("this turn: 1 tool calls")
    end

    it "shows nothing at the turn's end without a card" do
      p = plugin("after" => 5)
      turn(p)
      tools(p, "read")
      fire(p, :after_turn, status: "completed")
      expect(p.cards).to be_empty
    end
  end

  describe "the card's actions" do
    let!(:p) { plugin("after" => 2, "every" => 3).tap { |pl| turn(pl) && tools(pl, "read", "read") } }

    it "Nudge steers the message with the count and closes the card" do
      expect(checkin(p, "nudge")).to be_nil

      expect(steers(p)).to eq(["You've made 2 tool calls in this turn without answering. Say briefly what you've found " \
                               "so far and what's left, then answer now or continue."])
      expect(p.cards.last).to include(title: "check-in", body: "Nudged the model at 2 tool calls.")
    end

    it "Nudge says at the turn's end that the nudge wasn't sent when the answer came first" do
      checkin(p, "nudge")
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, { role: "model", content: "done" }])

      expect(p.cards.last).to include(id: p.cards.first[:id], title: "check-in", body: "The answer came first; nudge not sent.")
    end

    it "Nudge keeps its card when the steer joined the turn" do
      checkin(p, "nudge")
      steer = { role: "user", kind: "steer", source: "check-in", content: steers(p).last }
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, steer, { role: "model", content: "done" }])

      expect(p.cards.last[:body]).to eq("Nudged the model at 2 tool calls.")
    end

    it "Nudge says the turn ended first when it was stopped before the nudge joined" do
      checkin(p, "nudge")
      fire(p, :after_turn, status: "canceled", messages: [{ role: "user", content: "go" }])

      expect(p.cards.last[:body]).to eq("The turn ended first; nudge not sent.")
    end

    it "Keep going closes the card and names the next check-in; the card comes back there" do
      expect(checkin(p, "later")).to be_nil
      expect(p.cards.last[:body]).to eq("Kept going; the next check-in is at 5 tool calls.")
      expect(checkin(p, "later")).to eq("check-in: no check-in open")

      tools(p, "read", "read", "read")
      expect(p.cards.last).to include(title: "5 tool calls, no answer yet", id: p.cards.first[:id])
    end

    it "Stop stops the turn and closes the card" do
      expect(checkin(p, "stop")).to be_nil
      expect(p.stops.map(&:reason)).to eq(["stopped from check-in"])
      expect(p.cards.last[:body]).to eq("Stopped the turn at 2 tool calls.")
    end

    it "steers once for 12 Nudge clicks on the same check-in; the next check-in can be nudged again" do
      results = Array.new(12) { checkin(p, "nudge") }

      expect(p.steers.size).to eq(1)
      expect(results.first).to be_nil
      expect(results.drop(1).uniq).to eq(["check-in: already nudged at 2 tool calls"])

      tools(p, "read", "read", "read")
      expect(checkin(p, "nudge")).to be_nil
      expect(checkin(p, "nudge")).to eq("check-in: already nudged at 5 tool calls")
      expect(p.steers.size).to eq(2)
    end

    it "lets a Nudge that found no turn be clicked again once one runs" do
      p.set(running: false)
      expect(checkin(p, "nudge")).to eq("check-in: no turn running")
      p.set(running: true)
      expect(checkin(p, "nudge")).to be_nil
      expect(p.steers.size).to eq(1)
    end

    it "steers once for a fresh worker's plugin clicked from a stale card (no check-in this turn)" do
      fresh = plugin("after" => 50).tap { |pl| turn(pl) && tools(pl, "read") }
      results = Array.new(5) { checkin(fresh, "nudge") }

      expect(fresh.steers.size).to eq(1)
      expect(results.drop(1).uniq).to eq(["check-in: already nudged at 1 tool calls"])
    end

    it "with no turn running, Nudge and Stop say so and leave the card" do
      p.set(running: false)
      cards = p.cards.size

      expect(checkin(p, "nudge")).to eq("check-in: no turn running")
      expect(checkin(p, "stop")).to eq("check-in: no turn running")
      expect(p.cards.size).to eq(cards)
    end
  end

  describe "modes nudge and notify" do
    it "nudge steers through the event with a custom message and says so" do
      p = plugin("after" => 2, "mode" => "nudge", "message" => "{calls} calls: status?")
      turn(p)
      tools(p, "read", "read")

      expect(steers(p)).to eq(["2 calls: status?"])
      expect(notices(p)).to eq([["nudged the model after 2 tool calls", :info]])
      expect(p.cards).to be_empty
    end

    it "notify only says so" do
      p = plugin("after" => 1, "every" => 1, "mode" => "notify")
      turn(p)
      tools(p, "read", "read")

      expect(notices(p).map(&:first)).to eq(["1 tool calls in this turn, no answer yet", "2 tool calls in this turn, no answer yet"])
      expect(p.steers).to be_empty
      expect(p.cards).to be_empty
    end

    it "a Nudge click after the mode's own nudge for that check-in is a repeat" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")

      expect(checkin(p, "nudge")).to eq("check-in: already nudged at 2 tool calls")
      # Only the mode's own nudge: the click steered nothing.
      expect(steers(p)).to eq([p.namespace::Plugin::DEFAULT_MESSAGE.gsub("{calls}", "2")])
    end

    it "nudge says at the turn's end that the nudge wasn't sent when the answer came first" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, { role: "model", content: "done" }])

      expect(notices(p).last).to eq(["The answer came first; nudge not sent.", :warn])
    end

    it "nudge says nothing at the turn's end when the steer joined the turn" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")
      steer = { role: "user", kind: "steer", source: "check-in", content: steers(p).last }
      fire(p, :after_turn, status: "completed", messages: [{ role: "user", content: "go" }, steer, { role: "model", content: "done" }])

      expect(notices(p).map(&:first)).to eq(["nudged the model after 2 tool calls"])
    end

    it "nudge says nothing at the turn's end when a user line was merged after the steer" do
      p = plugin("after" => 2, "mode" => "nudge")
      turn(p)
      tools(p, "read", "read")
      steer = { role: "user", kind: "steer", source: "check-in", content: steers(p).last }
      merged = { role: "user", kind: "input", content: "also this" }
      fire(p, :after_turn, status: "completed",
                           messages: [{ role: "user", content: "go" }, steer, merged, { role: "model", content: "done" }])

      expect(notices(p).map(&:first)).to eq(["nudged the model after 2 tool calls"])
    end
  end

  describe "/checkin" do
    let(:p) { plugin }

    it "reports its state, and changes it for this session" do
      expect(checkin(p)).to eq("check-in is on: mode ask, after 50 tool calls, then every 50; this turn: 0 tool calls")
      expect(checkin(p, "off")).to eq("check-in is off for this session")
      expect(checkin(p, "mode nudge")).to eq("check-in mode is nudge for this session")
      expect(checkin(p, "mode loud")).to eq("check-in: unknown mode loud (ask, nudge or notify)")
      expect(checkin(p, "30")).to eq("check-in after 30 tool calls, then every 30, for this session")
      expect(checkin(p, "0")).to eq("check-in: the threshold must be at least 1")
      expect(checkin(p)).to eq("check-in is off: mode nudge, after 30 tool calls, then every 30; this turn: 0 tool calls")
      expect(checkin(p, "what")).to start_with("usage: /checkin")
    end

    it "keeps the session's changes across a restart (a new plugin), and only that session's" do
      checkin(p, "off")
      checkin(p, "mode nudge")
      checkin(p, "30")
      restarted = plugin
      expect(checkin(restarted)).to eq("check-in is off: mode nudge, after 30 tool calls, then every 30; this turn: 0 tool calls")

      restarted.set(session_id: "s2")
      expect(checkin(restarted)).to eq("check-in is on: mode ask, after 50 tool calls, then every 50; this turn: 0 tool calls")
      turn(restarted)
      restarted.set(session_id: "s1")
      turn(restarted)
      expect(checkin(restarted)).to start_with("check-in is off: mode nudge, after 30 tool calls")
      expect(Dir.children(File.join(p.ctx.data_dir, "sessions"))).to eq(["s1.json"])
    end

    it "a restored threshold counts from the session's next turn" do
      checkin(p, "2")
      restarted = plugin
      turn(restarted)
      tools(restarted, "a", "b")
      expect(restarted.cards.last[:title]).to eq("2 tool calls, no answer yet")
    end

    it "off stops the check-ins; on brings them back" do
      checkin(p, "3")
      checkin(p, "off")
      turn(p)
      tools(p, "a", "b", "c")
      expect(p.cards).to be_empty

      checkin(p, "on")
      tools(p, "d")
      expect(p.cards.size).to eq(1)
    end

    it "a threshold a running turn is already past checks in that many calls from now" do
      turn(p)
      tools(p, *Array.new(10, "read"))
      checkin(p, "4")

      tools(p, "a", "b", "c")
      expect(p.cards).to be_empty
      tools(p, "d")
      expect(p.cards.last[:title]).to eq("14 tool calls, no answer yet")
    end
  end

  # docs/system-one.md, Bundles' judgments: the ask at each check-in and the
  # labels of what the user then did, on the kit's fake System 1.
  describe "the progress judgment" do
    # chi's default is no mode at all (off); the kit needs the mode and an answer.
    def judging(p, mode: "audit")
      p.judgments.mode("progress", mode)
      p.judgments.answer("progress", noul: 0.4)
    end

    # A tool call as chi's ToolRunner fires it (docs/hooks.md, Hook Events).
    def tool_call(p, tool, args: {}, result: "ok")
      fire(p, :after_tool_call, tool: tool, output: result, status: "ok", iteration: 1, elapsed_ms: 4,
           call: { name: tool, arguments: args }, result: result)
    end

    def labels(p) = p.judgments.labels("progress")

    # The run of the check-in at +calls+ tool calls (the asks are on a side
    # thread, so the runs are not in order).
    def run_at(p, calls)
      p.judgments.runs("progress").find { |run| run["state"]["calls"] == calls }
    end

    it "asks at each check-in with the prompt, the calls since the last one, the count and the time" do
      p = plugin("after" => 2, "every" => 3)
      judging(p)
      turn(p)
      tool_call(p, "read", args: { path: "a.rb" }, result: "the file")
      tool_call(p, "execute", args: { command: "ls" }, result: "one two")
      p.judgments.wait

      runs = p.judgments.runs("progress")
      expect(runs.size).to eq(1)
      run = runs.last
      expect([run["judgment"], run["asked"], run["mode"], run["session_model"]]).to eq(["check-in.progress", true, "audit", "test:model"])
      state = run["state"]
      expect([state["prompt"], state["calls"]]).to eq(["go", 2])
      expect(state["elapsed_s"]).to be_between(0, 60)
      expect(state["tools"]).to eq(['read {"path":"a.rb"} -> the file', 'execute {"command":"ls"} -> one two'])
    end

    it "keeps what a call asked for, without its name or nil fields, as the real call hash has them" do
      p = plugin("after" => 1)
      judging(p)
      turn(p)
      fire(p, :after_tool_call, tool: "execute", call: { name: "execute", content: "echo 1", path: nil, scope: nil }, output: "1")
      p.judgments.wait
      expect(p.judgments.runs("progress").last["state"]["tools"]).to eq(['execute {"content":"echo 1"} -> 1'])
    end

    it "sends only the calls since the last check-in, each cut as it is captured" do
      p = plugin("after" => 2, "every" => 2)
      judging(p)
      turn(p)
      tool_call(p, "read", args: { path: "a" * 400 }, result: "x" * 900)
      tool_call(p, "execute", args: { command: "ls" }, result: "y")
      tool_call(p, "grep", args: { pattern: "z" }, result: "found")
      tool_call(p, "read", args: { path: "b" }, result: "second")
      p.judgments.wait

      runs = p.judgments.runs("progress")
      expect(runs.size).to eq(2)
      first, second = [run_at(p, 2), run_at(p, 4)].map { |run| run["state"] }
      expect([first["calls"], second["calls"]]).to eq([2, 4])
      expect(second["tools"]).to eq(['grep {"pattern":"z"} -> found', 'read {"path":"b"} -> second'])
      expect(first["tools"].first).to start_with('read {"path":"aaa')
      expect(first["tools"].first).to end_with("…")
      expect(first["tools"].first.length).to be <= 340
    end

    it "keeps the calls under about 4 KB, dropping the oldest" do
      p = plugin("after" => 20, "every" => 20)
      judging(p)
      turn(p)
      20.times { |i| tool_call(p, "execute", args: { command: "cat file#{i}" }, result: "y" * 400) }
      p.judgments.wait

      tools = p.judgments.runs("progress").last["state"]["tools"]
      expect(tools.size).to be_between(10, 19)
      expect(tools.join.bytesize).to be <= 4096
      expect(tools.last).to eq('execute {"command":"cat file19"} -> ' + ("y" * 200) + "…")
    end

    it "asks nothing and saves nothing while no mode is set, and the card works as before" do
      p = plugin("after" => 2)
      turn(p)
      tools(p, "read", "read")
      expect(p.judgments.asks).to be_empty
      expect(p.judgments.runs("progress")).to be_empty

      expect(p.cards.last[:title]).to eq("2 tool calls, no answer yet")
      expect(checkin(p, "nudge")).to be_nil
      expect(checkin(p, "later")).to eq("check-in: no check-in open")
      expect(steers(p).size).to eq(1)
      expect(labels(p)).to be_empty
    end

    it "labels what the card's action did, on the latest check-in's run" do
      p = plugin("after" => 2, "every" => 4)
      judging(p)
      turn(p)
      tool_call(p, "read", result: "a")
      tool_call(p, "read", result: "b")
      p.judgments.wait
      run = p.judgments.runs("progress").last["id"]

      expect(checkin(p, "nudge")).to be_nil
      expect(labels(p).size).to eq(1)
      expect(labels(p).first).to include("kind" => "label", "run_id" => run, "value" => "nudge",
                                         "by" => "check-in:card", "strength" => "weak")

      # A repeat Nudge, a Keep going with no card and a Stop with no card: no label.
      expect(checkin(p, "nudge")).to eq("check-in: already nudged at 2 tool calls")
      expect(checkin(p, "later")).to eq("check-in: no check-in open")
      expect(checkin(p, "stop")).to be_nil
      expect(labels(p).size).to eq(1)

      # The next check-in, and Stop on the card it opens.
      tools(p, "read", "read", "read", "read")
      p.judgments.wait
      expect(checkin(p, "stop")).to be_nil
      expect(labels(p).map { |line| [line["value"], line["run_id"]] }).to eq(
        [["nudge", run], ["stop", run_at(p, 6)["id"]]]
      )
    end

    it "labels the turn's end when the card was still open, and nothing when it wasn't" do
      p = plugin("after" => 1, "every" => 1)
      judging(p)
      turn(p)
      tool_call(p, "read", result: "a")
      p.judgments.wait

      expect(checkin(p, "later")).to be_nil
      expect(labels(p).map { |line| [line["value"], line["by"], line["strength"]] })
        .to eq([["keep_going", "check-in:card", "weak"]])

      tool_call(p, "read", result: "b")
      p.judgments.wait
      fire(p, :after_turn, status: "completed")
      expect(labels(p).map { |line| [line["value"], line["by"], line["strength"]] })
        .to eq([["keep_going", "check-in:card", "weak"], ["turn_stopped", "check-in:turn", nil]])

      p2 = plugin("after" => 5)
      judging(p2)
      turn(p2)
      tool_call(p2, "read", result: "a")
      fire(p2, :after_turn, status: "completed")
      expect(p2.judgments.asks).to be_empty
      expect(labels(p2)).to be_empty
    end

    it "asks in nudge and notify modes, where there is no card to label" do
      p = plugin("after" => 1, "mode" => "nudge")
      judging(p)
      turn(p)
      tool_call(p, "read", result: "a")
      p.judgments.wait

      expect(p.judgments.asks.size).to eq(1)
      expect(checkin(p, "nudge")).to eq("check-in: already nudged at 1 tool calls")
      expect(labels(p)).to be_empty
    end

    it "saves no prompt for a turn someone else is running, or for a continue" do
      p = plugin("after" => 1)
      judging(p)
      p.set(turn_author: "p:1")
      turn(p)
      tool_call(p, "read", result: "a")
      p.judgments.wait
      expect(p.judgments.asks.last.state["prompt"]).to be_nil

      p2 = plugin("after" => 1)
      judging(p2)
      fire(p2, :before_turn, prompt: nil, resumed: true)
      tool_call(p2, "read", result: "a")
      p2.judgments.wait
      expect(p2.judgments.asks.last.state["prompt"]).to be_nil
    end

    it "a restarted plugin has no run to label, so a click labels nothing" do
      p = plugin("after" => 2)
      judging(p)
      turn(p)
      tools(p, "read", "read")
      p.judgments.wait
      expect(checkin(p, "nudge")).to be_nil

      restarted = plugin("after" => 2)
      judging(restarted)
      expect(checkin(restarted, "nudge")).to be_nil
      expect(restarted.judgments.labels("progress")).to be_empty
      expect(restarted.judgments.runs("progress")).to be_empty
    end

    it "changes nothing the user sees: the card, its actions and its notices are the same" do
      p = plugin("after" => 2, "every" => 2)
      judging(p, mode: "on")
      turn(p)
      tools(p, "read", "read")
      p.judgments.wait

      expect(notices(p)).to be_empty
      expect(steers(p)).to be_empty
      expect(p.cards.last[:title]).to eq("2 tool calls, no answer yet")
      expect(p.cards.last[:actions]).to eq([{ label: "Nudge", command: "/checkin nudge" },
                                            { label: "Keep going", command: "/checkin later" },
                                            { label: "Stop", command: "/checkin stop" }])
      expect(checkin(p, "later")).to be_nil
      expect(p.cards.last[:body]).to eq("Kept going; the next check-in is at 4 tool calls.")
    end
  end
end
