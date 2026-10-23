# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/send_command"

# Which turn chi send --wait waits for and reports, per run path.
RSpec.describe Samagotchi::SendCommand::WaitTarget do
  def delivered(via, id = "e1")
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: via, ack: { "enqueued_id" => id })
  end

  describe ".first_message" do
    it "waits for a file-delivered message's own turn, and the next reply through the Bridge" do
      expect(described_class.first_message(delivered(:file)).to_h).to include(turn: "e1", report_turn_id: "e1")
      expect(described_class.first_message(delivered(:bridge)).to_h).to include(turn: nil, report_turn_id: "e1")
      expect(described_class.first_message(nil)).to eq(described_class.new)
    end
  end

  describe ".message" do
    it "waits for a queue's own turn, queued" do
      target = described_class.message(delivered(:bridge), queue: true, running: true, running_turn: "r0")
      expect(target.to_h).to eq(turn: "e1", report_turn_id: "e1", queued: true, ended_before: false)
    end

    # The worker queues the owner's plain message behind a participant's
    # review turn (its ack says queue): the wait is for its own turn, never
    # the participant's reply.
    it "waits for a plain message's own turn when the worker queued it" do
      queued = Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge,
                                                             ack: { "enqueued_id" => "e1", "delivery" => "queue" })
      expect(described_class.message(queued, queue: false, running: true, running_turn: "r0").to_h)
        .to eq(turn: "e1", report_turn_id: "e1", queued: true, ended_before: false)
    end

    it "takes the next reply for a plain message, reported as the running turn's, or its own when idle" do
      expect(described_class.message(delivered(:bridge), queue: false, running: true, running_turn: "r0").to_h)
        .to include(turn: nil, report_turn_id: "r0", queued: false)
      expect(described_class.message(delivered(:bridge), queue: false, running: false, running_turn: nil).to_h)
        .to include(turn: nil, report_turn_id: "e1")
      expect(described_class.message(delivered(:file), queue: false, running: false, running_turn: nil).to_h)
        .to include(turn: "e1", queued: false)
    end
  end

  describe ".wait_only" do
    let(:tmpdir) { Dir.mktmpdir("wait-target") }

    after { FileUtils.rm_rf(tmpdir) }

    def session(status:, last_turn: nil)
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
        s.status = status
        s.last_turn = last_turn
      end
    end

    it "takes a settled session's last turn as ended before, and --turn's own" do
      idle = session(status: "idle", last_turn: { "outcome" => "completed", "ended_at" => "t", "enqueued_id" => "l1" })
      expect(described_class.wait_only(idle, session_dir: tmpdir, requested: nil).to_h)
        .to include(turn: nil, report_turn_id: "l1", ended_before: true)
      expect(described_class.wait_only(idle, session_dir: tmpdir, requested: "l1").to_h)
        .to include(turn: "l1", report_turn_id: "l1", ended_before: true)
      expect(described_class.wait_only(session(status: "idle"), session_dir: tmpdir, requested: nil).to_h)
        .to include(turn: nil, report_turn_id: nil, ended_before: false)
    end
  end
end
