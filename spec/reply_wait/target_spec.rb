# frozen_string_literal: true

require "spec_helper"
require "samagotchi/reply_wait"
require "samagotchi/session_access"
require "samagotchi/session_manager"
require "samagotchi/tools/delegate_cursor"

# Which turn a reply wait waits for and reports, per caller.
RSpec.describe Samagotchi::ReplyWait::Target do
  let(:baseline) { Samagotchi::ReplyWait::Baseline.new(messages: 2) }

  def delivered(via, id = "e1")
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: via, ack: { "enqueued_id" => id })
  end

  def start(cursor: "c.txt", own_turn: nil, running: false, live: true, settled: false, last_turn_id: nil)
    Samagotchi::SessionAccess::WaitStart.new(cursor: cursor, baseline: baseline, own_turn: own_turn, known_turn: nil,
                                             running: running, live: live, settled: settled, last_turn_id: last_turn_id)
  end

  def first_message(delivery, direct_turn: nil)
    described_class.first_message(start, delivery, direct_turn: direct_turn)
  end

  it "gives every caller's wait one dead-worker rule, ReplyWait::GONE_AFTER (5 s)" do
    expect(Samagotchi::ReplyWait::GONE_AFTER).to eq(5)
  end

  describe ".first_message" do
    it "waits for the message's own turn, file-delivered or through the Bridge, not queued (a merge falls back)" do
      expect(first_message(delivered(:file))).to have_attributes(turn: "e1", report_turn_id: "e1")
      expect(first_message(delivered(:bridge))).to have_attributes(turn: "e1", report_turn_id: "e1", queued: false)
      expect(first_message(delivered(:bridge, nil))).to have_attributes(turn: nil, report_turn_id: nil)
      expect(first_message(nil)).to eq(described_class.new(cursor: "c.txt", baseline: baseline, owner_grace: 5))
    end

    # A session created with the prompt: no delivery, but the create gave
    # that turn an id (Session#first_turn_id), so the wait and the give-up's
    # hint name it.
    it "waits for a direct start's first turn by the id the create gave it" do
      expect(first_message(nil, direct_turn: "t1").to_h)
        .to eq(cursor: "c.txt", baseline: baseline, owner_grace: 5, turn: "t1", queued: true, ended_before: false)
      expect(first_message(nil, direct_turn: "t1").report_turn_id).to eq("t1")
      expect(first_message(nil, direct_turn: nil)).to eq(described_class.new(cursor: "c.txt", baseline: baseline,
                                                                             owner_grace: 5))
      # Through the worker (images, a command) the ack's id is the turn, not
      # the create's.
      expect(first_message(delivered(:bridge), direct_turn: "t1")).to have_attributes(turn: "e1", report_turn_id: "e1")
    end
  end

  describe ".message" do
    def message(delivery, queue:, running:, own_turn: nil)
      described_class.message(start(running: running, own_turn: own_turn), delivery, queue: queue)
    end

    it "waits for a queue's own turn, queued" do
      expect(message(delivered(:bridge), queue: true, running: true, own_turn: "r0"))
        .to have_attributes(turn: "e1", report_turn_id: "e1", queued: true, ended_before: false, cursor: "c.txt",
                            baseline: baseline, owner_grace: 5)
    end

    # The worker queues the owner's plain message behind a participant's
    # review turn (its ack says queue): the wait is for its own turn, never
    # the participant's reply.
    it "waits for a plain message's own turn when the worker queued it" do
      queued = Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge,
                                                             ack: { "enqueued_id" => "e1", "delivery" => "queue" })
      expect(message(queued, queue: false, running: true, own_turn: "r0"))
        .to have_attributes(turn: "e1", report_turn_id: "e1", queued: true, ended_before: false)
    end

    it "waits for a plain message's own turn on an idle session; on a running one, the next reply, reported as its turn's" do
      expect(message(delivered(:bridge), queue: false, running: true, own_turn: "r0"))
        .to have_attributes(turn: nil, report_turn_id: "r0", queued: false)
      expect(message(delivered(:bridge), queue: false, running: false))
        .to have_attributes(turn: "e1", report_turn_id: "e1", queued: false)
      expect(message(delivered(:bridge, nil), queue: false, running: false))
        .to have_attributes(turn: nil, report_turn_id: nil)
      expect(message(delivered(:file), queue: false, running: false)).to have_attributes(turn: "e1", queued: false)
    end
  end

  describe ".wait_only" do
    it "takes a settled session's last turn as ended before, and --turn's own" do
      settled = start(settled: true, last_turn_id: "l1")
      expect(described_class.wait_only(settled, requested: nil))
        .to have_attributes(turn: nil, report_turn_id: "l1", ended_before: true)
      expect(described_class.wait_only(settled, requested: "l1"))
        .to have_attributes(turn: "l1", report_turn_id: "l1", ended_before: true)
      expect(described_class.wait_only(start, requested: nil))
        .to have_attributes(turn: nil, report_turn_id: nil, ended_before: false)
    end

    it "waits for the turn running now, and on a session no worker runs for whatever wakes one (no grace)" do
      expect(described_class.wait_only(start(own_turn: "r0"), requested: nil))
        .to have_attributes(turn: "r0", report_turn_id: "r0", owner_grace: 5)
      expect(described_class.wait_only(start(live: false), requested: nil).owner_grace).to be_nil
    end
  end

  describe ".answer" do
    it "waits for the turn the question is about, else the next reply" do
      expect(described_class.answer(start(own_turn: "r0")).to_h)
        .to eq(cursor: "c.txt", baseline: baseline, owner_grace: 5, turn: "r0", queued: false, ended_before: false)
      expect(described_class.answer(start(own_turn: "r0")).report_turn_id).to eq("r0")
      expect(described_class.answer(start)).to have_attributes(turn: nil, report_turn_id: nil)
    end
  end

  describe ".participant" do
    it "waits for the review turn just queued, as --turn T" do
      expect(described_class.participant(start(last_turn_id: "p1"), turn: "p1"))
        .to have_attributes(turn: "p1", report_turn_id: "p1", ended_before: true, owner_grace: 5)
      expect(described_class.participant(start(live: false), turn: "p1"))
        .to have_attributes(turn: "p1", ended_before: false, owner_grace: nil)
    end
  end

  describe ".from_cursor" do
    let(:cursor) { Samagotchi::Tools::DelegateCursor.new(reply_file: "r.txt").with_baseline(baseline) }
    let(:child) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w") }

    it "waits past the parent's reply, from the child as it was, on the follow-up's turn" do
      target = described_class.from_cursor(cursor.with(turn: "f1"), child: child, owner_grace: 15)
      expect(target.to_h).to eq(cursor: "r.txt", baseline: cursor.baseline, owner_grace: 15, turn: "f1", queued: false,
                                ended_before: false)
      expect(described_class.from_cursor(cursor, child: nil)).to have_attributes(turn: nil, queued: false, owner_grace: nil)
    end

    it "binds the child's first turn as queued: nothing merges into it" do
      child.first_turn_id = "t1"
      expect(described_class.from_cursor(cursor.with(turn: "t1"), child: child)).to have_attributes(turn: "t1", queued: true)
      expect(described_class.from_cursor(cursor, child: child)).to have_attributes(turn: nil, queued: false)
    end
  end
end
