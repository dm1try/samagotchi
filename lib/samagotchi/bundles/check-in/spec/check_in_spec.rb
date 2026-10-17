# frozen_string_literal: true

require "samagotchi/testing/rspec"

# The check-in plugin on its own, through the bundle test kit (docs/plugins.md,
# "Testing a bundle"); spec/samagotchi/plugin/check_in_bundle_spec.rb installs it
# and runs real turns.
RSpec.describe "The check-in plugin", :bundle do
  # The plugin as chi loads it, for session s1. Each call is a new load (a
  # worker's restart): the same sandbox, so the same data dir.
  def plugin(settings = {}) = shipped_bundle("check-in", settings: settings, host: { session_id: "s1" })

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
end
