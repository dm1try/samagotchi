# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

require "samagotchi/participants"
require "samagotchi/archive_store"

# A session's participants: the sidecar the worker reads, the audit trail,
# and the invite/revoke steps that keep them with Web::Grants.
RSpec.describe Samagotchi::Participants do
  let(:root) { Dir.mktmpdir("participants") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap { |s| s.save(state_dir: state_dir) }
  end
  let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }

  after { FileUtils.remove_entry(root) }

  def audit = File.readlines(File.join(dir, described_class::LOG)).map { |line| JSON.parse(line) }

  it "leaves a session nobody was invited to without either file" do
    session
    expect(described_class.read(session.id, state_dir: state_dir)).to eq([])
    expect(Dir.exist?(dir) ? Dir.children(dir) : []).not_to include(described_class::FILE, described_class::LOG)
  end

  describe ".invite" do
    it "issues the grant and writes the sidecar (no token, no digest) and an audit line, both 0600" do
      FileUtils.mkdir_p(dir)
      issued = described_class.invite(grants, session_id: session.id, name: "Alex", kind: "agent", state_dir: state_dir)

      entries = described_class.read(session.id, state_dir: state_dir)
      expect(entries.map(&:to_h)).to eq([{ id: issued.grant.id, kind: "agent", name: "Alex", role: "reviewer",
                                           added_at: issued.grant.created_at, expires_at: issued.grant.expires_at,
                                           removed_at: nil, cap: 2.0 }])
      expect(entries.first.active?(Time.now)).to be(true)
      sidecar = File.read(File.join(dir, described_class::FILE))
      expect(sidecar).not_to include(issued.token)
      expect(sidecar).not_to include(issued.grant.digest)
      expect(audit.map { |line| line.slice("event", "participant", "name") })
        .to eq([{ "event" => "issued", "participant" => issued.grant.id, "name" => "Alex" }])
      [described_class::FILE, described_class::LOG].each do |name|
        expect(File.stat(File.join(dir, name)).mode & 0o777).to eq(0o600)
      end
    end

    it "leaves the session JSON byte for byte as it was" do
      FileUtils.mkdir_p(dir)
      before = File.binread(Samagotchi::Session.session_file(session.id, state_dir: state_dir))
      described_class.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      expect(File.binread(Samagotchi::Session.session_file(session.id, state_dir: state_dir))).to eq(before)
    end

    it "refuses an unknown session and an archived one" do
      expect { described_class.invite(grants, session_id: "nope", name: "A", state_dir: state_dir) }
        .to raise_error(ArgumentError, /Session not found: nope/)
      FileUtils.mkdir_p(dir)
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      expect { described_class.invite(grants, session_id: session.id, name: "A", state_dir: state_dir) }
        .to raise_error(Samagotchi::Web::Grants::Invalid, /is archived: unarchive it/)
      expect(grants.list).to eq([])
    end
  end

  describe ".revoke" do
    it "marks the participant removed in the sidecar and audits who revoked it" do
      FileUtils.mkdir_p(dir)
      issued = described_class.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      revoked = described_class.revoke(grants, session_id: session.id, by: "archive", state_dir: state_dir)

      expect(revoked.map(&:id)).to eq([issued.grant.id])
      entry = described_class.read(session.id, state_dir: state_dir).first
      expect(entry.removed_at).not_to be_nil
      expect(entry.active?(Time.now)).to be(false)
      expect(audit.last.slice("event", "participant", "by")).to eq("event" => "revoked", "participant" => issued.grant.id,
                                                                   "by" => "archive")
    end
  end
end
