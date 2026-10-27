# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

require "samagotchi/participants"
require "samagotchi/archive_store"
require "samagotchi/web/public_url"

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
                                           removed_at: nil, cap: 2.0, mode: nil }])
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

  describe ".invite bound to an identity" do
    let(:proxy) do
      Samagotchi::Web::PublicUrl.from_config(url: "https://chi.corp.test", identity_header: "X-Forwarded-Email")
    end

    before { FileUtils.mkdir_p(dir) }

    it "binds the grant behind a proxy that names the user, and audits the identity" do
      issued = described_class.invite(grants, session_id: session.id, name: "Alex", identity: " Alex@Corp.Test ",
                                              public_url: proxy, state_dir: state_dir)
      expect(issued.grant.identity).to eq("alex@corp.test")
      expect(audit.last).to include("event" => "issued", "identity" => "alex@corp.test")
      sidecar = File.read(File.join(dir, described_class::FILE))
      expect(sidecar).not_to include(issued.token)
    end

    it "refuses an identity with no proxy, or a proxy that names nobody (a link that would never open)" do
      token_only = Samagotchi::Web::PublicUrl.from_config(url: "https://chi.corp.test")
      [nil, token_only].each do |public_url|
        expect do
          described_class.invite(grants, session_id: session.id, name: "Alex", identity: "alex@corp.test",
                                         public_url: public_url, state_dir: state_dir)
        end.to raise_error(Samagotchi::Web::Grants::Unbindable, /only on a chi web behind an auth proxy that names the signed-in user/)
      end
      expect(grants.list).to eq([])
      expect(File.exist?(File.join(dir, described_class::LOG))).to be(false)
    end

    it "audits no identity for an unbound grant" do
      described_class.invite(grants, session_id: session.id, name: "Alex", public_url: proxy, state_dir: state_dir)
      expect(audit.last).not_to have_key("identity")
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

  describe ".end_sessions" do
    it "doesn't stop an archive or delete over a grants store that can't be read, and leaves the store as it was" do
      FileUtils.mkdir_p(dir)
      described_class.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      File.write(grants.path, "[broken")
      allow(Samagotchi::Log).to receive(:warn)
      expect { described_class.end_sessions([session.id], by: "archive", state_dir: state_dir) }.not_to raise_error
      expect(File.read(grants.path)).to eq("[broken")
    end
  end

  # L-P2: chi web and a chi share run each change the grants store under its
  # lock; the sidecar the worker reads must be written under the same lock,
  # or two writers finishing out of order can lose a revoke there.
  describe "the sidecar and the grants lock" do
    def lock_held?
      lock = File.join(File.dirname(grants.path), Samagotchi::Web::Grants::LOCK)
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |io|
        # Another open file description: refused while the lock is held.
        !io.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end

    def sidecar_writes_under_lock
      seen = []
      allow(described_class).to receive(:write).and_wrap_original do |original, *args, **kwargs|
        seen << lock_held?
        original.call(*args, **kwargs)
      end
      yield
      seen
    end

    before { FileUtils.mkdir_p(dir) }

    it "is written while the store's lock is held: invite, set_cap and revoke" do
      id = nil
      expect(sidecar_writes_under_lock do
        id = described_class.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir).grant.id
      end).to eq([true])
      expect(sidecar_writes_under_lock do
        described_class.set_cap(grants, session_id: session.id, id: id, cap: 5, state_dir: state_dir)
      end).to eq([true])
      expect(sidecar_writes_under_lock do
        described_class.revoke(grants, session_id: session.id, state_dir: state_dir)
      end).to eq([true])
      expect(described_class.read(session.id, state_dir: state_dir).first.removed_at).not_to be_nil
    end

    it "writes each revoked session's sidecar under the lock (a revoke of every session's)" do
      other = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root)
      other.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(other.id, state_dir: state_dir))
      described_class.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
      described_class.invite(grants, session_id: other.id, name: "Sam", state_dir: state_dir)

      expect(sidecar_writes_under_lock { described_class.revoke(grants, state_dir: state_dir) }).to eq([true, true])
      [session.id, other.id].each do |sid|
        expect(described_class.read(sid, state_dir: state_dir).map(&:removed_at)).to all(be_a(String))
      end
    end
  end
end
