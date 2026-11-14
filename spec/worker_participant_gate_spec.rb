# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require "support/outdated_grants"
require "samagotchi/worker_participant_gate"
require "samagotchi/session"
require "samagotchi/session_inbox"
require "samagotchi/turn_origin"

# May this participant act: the Worker's one seat (its turn start, the
# drain, the mid-turn stop, the Continue), on a real participants.json.
RSpec.describe Samagotchi::WorkerParticipantGate do
  include OutdatedGrants

  let(:tmpdir) { Dir.mktmpdir("participant-gate") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |s|
      s.save(state_dir: tmpdir)
      # Its folder, where participants.json goes.
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir))
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: tmpdir)) }
  let(:spend) { Hash.new(0.0) }
  let(:announced) { [] }
  let(:engine) do
    metrics = double("metrics")
    allow(metrics).to receive(:spend) { |author| spend[author] }
    double("engine", metrics: metrics).tap do |engine|
      allow(engine).to receive(:announce) { |**event| announced << event }
      allow(engine).to receive(:announce_participants)
    end
  end
  let(:gate) do
    described_class.new(engine: engine, session: session, session_id: session.id, state_dir: tmpdir,
                        session_dir: session_dir, hook: "participants")
  end

  after { FileUtils.rm_rf(tmpdir) }

  def invite(name = "Alex", cap: nil)
    Samagotchi::Participants.invite(grants, session_id: session.id, name: name, cap: cap, state_dir: tmpdir).grant
  end

  def notices = announced.select { |event| event[:type] == :hook_notice }

  describe "#refusal" do
    it "lets the owner act (no participant author)" do
      expect(gate.refusal(nil)).to be_nil
      expect(gate.refusal("")).to be_nil
    end

    it "lets an invited participant under their cap act" do
      expect(gate.refusal(invite.author)).to be_nil
    end

    it "refuses an older chi's read-only invite (outdated), a revoked one and one never invited (revoked)" do
      outdated = make_outdated!(grants, invite("Old"), state_dir: tmpdir)
      revoked = invite("Gone")
      Samagotchi::Participants.revoke(grants, session_id: session.id, id: revoked.id, state_dir: tmpdir)

      expect(gate.refusal(outdated.author)).to eq("outdated")
      expect(gate.refusal(revoked.author)).to eq("revoked")
      expect(gate.refusal("p:p_nobody1")).to eq("revoked")
      expect(notices).to be_empty
    end

    it "refuses at the participant's own cap, else at the config's" do
      own = invite("Own", cap: 5.0)
      spend[own.author] = 4.99
      expect(gate.refusal(own.author)).to be_nil
      spend[own.author] = 5.0
      expect(gate.refusal(own.author)).to eq("cap_reached")

      config = File.join(tmpdir, "config")
      with_config_home(config) do
        path = File.join(config, "samagotchi", "config.yml")
        File.write(path, YAML.dump(YAML.load_file(path).merge("web" => { "participants" => { "cap" => 1.5 } })))
        other = invite("Other")
        spend[other.author] = 1.49
        expect(gate.refusal(other.author)).to be_nil
        spend[other.author] = 1.5
        expect(gate.refusal(other.author)).to eq("cap_reached")
      end
    end

    it "tells the owner once per participant and cap, and again for a raised cap reached" do
      grant = invite
      spend[grant.author] = 2.5
      3.times { expect(gate.refusal(grant.author)).to eq("cap_reached") }
      expect(notices.size).to eq(1)
      expect(notices.first).to include(hook: "participants", level: :warn, between_turns: true,
                                       text: "Alex reached their $2.00 cap: their turns stop and are refused until you " \
                                             "raise it (chi share cap #{session.id[0, 8]} #{grant.id} AMOUNT).")

      Samagotchi::Participants.set_cap(grants, session_id: session.id, id: grant.id, cap: 3.0, state_dir: tmpdir)
      expect(gate.refusal(grant.author)).to be_nil
      spend[grant.author] = 3.0
      2.times { expect(gate.refusal(grant.author)).to eq("cap_reached") }
      expect(notices.map { |event| event[:text][/\$\d+\.\d+/] }).to eq(["$2.00", "$3.00"])
    end
  end

  describe "#turn_stop" do
    it "is nil while they may act, else the cap's or the ended link's reason" do
      grant = invite
      expect(gate.turn_stop(grant.author)).to be_nil
      spend[grant.author] = 2.0
      expect(gate.turn_stop(grant.author)).to eq("Alex reached their $2.00 cap")
      Samagotchi::Participants.revoke(grants, session_id: session.id, id: grant.id, state_dir: tmpdir)
      expect(gate.turn_stop(grant.author)).to eq("Alex's link was revoked or expired")
      expect(gate.turn_stop(nil)).to be_nil
    end
  end

  describe "#refuse" do
    it "settles the queued turn as refused, audits it and drops it from every UI's queue" do
      grant = invite
      origin = Samagotchi::TurnOrigin.new(client_id: "participant:p", enqueued_id: "e1", author: grant.author)

      expect(gate.refuse(origin, "revoked")).to be_nil
      expect(Samagotchi::TurnCheckpoint.settled_turn(session_dir, "e1")).to have_attributes(author: grant.author)
      audit = File.readlines(File.join(session_dir, Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }
                  .select { |line| line["event"] == "turn" }
      expect(audit).to contain_exactly(include("participant" => grant.id, "enqueued_id" => "e1", "status" => "refused",
                                               "reason" => "revoked"))
      expect(announced).to eq([{ type: :turn_dequeued, enqueued_id: "e1", client_id: "participant:p" }])
    end
  end

  describe "#watch" do
    it "announces the participants, and only logs a failure" do
      gate.watch
      expect(engine).to have_received(:announce_participants)

      allow(engine).to receive(:announce_participants).and_raise(IOError, "boom")
      allow(Samagotchi::Log).to receive(:warn)
      expect { gate.watch }.not_to raise_error
      expect(Samagotchi::Log).to have_received(:warn).with(:worker, "participants_watch_failed", error: "IOError")
    end
  end
end
