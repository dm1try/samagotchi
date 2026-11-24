# frozen_string_literal: true

require "spec_helper"
require "samagotchi/peer_say"
require "samagotchi/worker_wakes"

# PeerSay#line: chi peer say's words for every case of the plan's P6.
RSpec.describe Samagotchi::PeerSay do
  def receipt(state, reason: nil, outcome: nil)
    Samagotchi::PeerReceipts::Receipt.new(serial: 12, state: state, reason: reason, outcome: outcome, turn: "t",
                                          at: "2026-11-24T10:00:00Z")
  end

  def say(**fields) = described_class.new(status: :received, serial: 12, **fields)

  it "names the setting the worker reads for peer turns" do
    expect(described_class::PEER_TURNS_KEY).to eq(Samagotchi::WorkerWakes::PEER_TURNS_KEY)
  end

  describe "a receipt within the wait" do
    it "says woke, noted and refused" do
      expect(say(receipt: receipt("woke")).line("claude")).to eq("#12 received · woke chi")
      expect(say(receipt: receipt("noted")).line("claude")).to eq("#12 received · noted")
      expect(say(receipt: receipt("refused", reason: "undeclared")).line("foo"))
        .to eq("#12 received · refused: no bundle in that session declares peer foo")
      expect(say(receipt: receipt("refused", reason: "invalid")).line("claude"))
        .to eq("#12 received · refused: chi couldn't read that message file")
    end

    it "says held with its reason's words and until when it waits" do
      expect(say(receipt: receipt("held", reason: "peer_turns"), turns: 3).line("claude"))
        .to eq("#12 received · held: 3 peer turns in a row (context.peer_turns) · waits for the user's next message")
      expect(say(receipt: receipt("held", reason: "peer_turns"), turns: 1).line("claude"))
        .to eq("#12 received · held: 1 peer turn in a row (context.peer_turns) · waits for the user's next message")
      expect(say(receipt: receipt("held", reason: "max_wakes"), turns: 10).line("claude"))
        .to eq("#12 received · held: 10 wake turns in a row (session.max_wakes) · waits for the user's next message")
      expect(say(receipt: receipt("held", reason: "off")).line("claude"))
        .to eq("#12 received · held: context.peer_turns is 0 · waits for the user's next message")
      expect(say(receipt: receipt("held", reason: "paused")).line("claude"))
        .to eq("#12 received · held: wakes are paused after a failed wake turn · waits for the user's next message")
      expect(say(receipt: receipt("held", reason: "continue")).line("claude"))
        .to eq("#12 received · held: a continue offer waits for the user · waits for the user's next message")
      expect(say(receipt: receipt("held", reason: "queued")).line("claude"))
        .to eq("#12 received · held: a message is queued ahead of it · chi reads it in its next turn")
      expect(say(receipt: receipt("held", reason: "leaving")).line("claude"))
        .to eq("#12 received · held: chi's worker is leaving · it reads this at its next start")
      expect(say(receipt: receipt("held", reason: "exit")).line("claude"))
        .to eq("#12 received · held: chi is exiting · it reads this at its next start")
    end

    it "says read and ended when the say saw the receipt move on" do
      expect(say(receipt: receipt("read")).line("claude")).to eq("#12 received · chi is reading it")
      expect(say(receipt: receipt("ended", outcome: "completed")).line("claude")).to eq("#12 received · chi read it (completed)")
      expect(say(receipt: receipt("ended", outcome: "canceled")).line("claude")).to eq("#12 received · chi read it (stopped)")
    end
  end

  it "says why it doesn't wait, at once" do
    { running: "chi is in a turn: it reads this when the turn ends",
      starting: "chi is starting",
      stopped: "chi is stopped: it reads this at its next start",
      archived: "this session is archived: it reads this if you reopen it",
      owned: "a one-turn chi run has this session: it reads this at its next start",
      start_failed: "chi's worker isn't running and couldn't be started from here: it reads this at its next start",
      no_turn: "chi hasn't had a turn yet: it reads this with its first" }.each do |wake, words|
      expect(say(wake: wake).line("claude")).to eq("#12 received · #{words}")
    end
  end

  it "says nothing came in the wait" do
    expect(say.line("claude")).to eq("#12 received · no answer from chi yet")
  end

  it "adds the peer's other held messages, a run per reason" do
    expect(say(receipt: receipt("woke"), earlier: [[10, "paused"], [11, "paused"]]).line("claude"))
      .to eq("#12 received · woke chi · also held: #10, #11 (paused)")
    expect(say(earlier: [[9, "peer_turns"], [10, "paused"]]).line("claude"))
      .to eq("#12 received · no answer from chi yet · also held: #9 (peer turns), #10 (paused)")
  end

  it "words each refusal" do
    expect(described_class.new(status: :gone).line("claude")).to eq("no such session")
    expect(described_class.new(status: :continued, next_id: "abcd-1234").line("claude"))
      .to eq("this session was continued as abcd-1234: say it there")
    expect(described_class.new(status: :not_paired).line("claude")).to eq("not paired: run the pair script")
    expect(described_class.new(status: :old_worker).line("claude")).to include("restart the session")
    expect(described_class.new(status: :full).line("claude")).to eq("chi has 200 unread messages from claude")
  end

  it "goes through JSON and back (a remote's say)" do
    original = say(receipt: receipt("held", reason: "peer_turns"), earlier: [[10, "paused"]], turns: 3)
    back = described_class.from_h(JSON.parse(JSON.generate(original.to_h)))
    expect(back).to eq(original)
    expect(described_class.from_h("status" => "bogus")).to be_nil
  end
end
