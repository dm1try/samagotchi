# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

require "samagotchi/web/grants"

# Participants' grants (Web::Grants): one token per session and participant,
# stored as a digest only, with an expiry and a revoke.
RSpec.describe Samagotchi::Web::Grants do
  let(:root) { Dir.mktmpdir("web-grants") }
  let(:path) { File.join(root, "samagotchi", "web-grants", "grants.json") }
  let(:now) { [Time.utc(2026, 10, 23, 12, 0, 0)] }
  let(:grants) { described_class.new(path, clock: -> { now.first }) }
  let(:session_id) { "3f9a1c2e-0000-4000-8000-000000000001" }

  after { FileUtils.remove_entry(root) }

  def advance(seconds) = now[0] += seconds

  def issue(**opts) = grants.issue(session_id: session_id, name: "Alex", **opts)

  describe ".path" do
    it "is web-grants/grants.json next to the sessions dir, beside web-token" do
      expect(described_class.path(state_dir: "/s/samagotchi/sessions")).to eq("/s/samagotchi/web-grants/grants.json")
    end
  end

  describe "#issue" do
    it "hands out a chp_ token once and keeps only its SHA-256 digest" do
      issued = issue

      expect(issued.token).to match(/\Achp_[A-Za-z0-9_-]{43}\z/)
      expect(issued.grant).to have_attributes(session_id: session_id, name: "Alex", kind: "human", role: "reviewer",
                                              created_at: "2026-10-23T12:00:00Z", expires_at: "2026-10-30T12:00:00Z")
      expect(issued.grant.id).to match(described_class::ID_RE)
      expect(issued.grant.author).to eq("p:#{issued.grant.id}")
      text = File.read(path)
      expect(text).not_to include(issued.token)
      expect(text).not_to include(issued.token.delete_prefix("chp_"))
      expect(JSON.parse(text)["grants"].first["digest"]).to eq(Digest::SHA256.hexdigest(issued.token))
      expect(issued.inspect).not_to include(issued.token)
    end

    it "writes the file 0600 in a 0700 folder" do
      issue
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    end

    it "takes an agent, a shorter expiry, and cleans the name to one bracket-free line" do
      grant = issue(kind: "agent", ttl: 3 * 86_400).grant
      expect(grant).to have_attributes(kind: "agent", expires_at: "2026-10-26T12:00:00Z")
      odd = grants.issue(session_id: session_id, name: "  [Owner]\nsays #{"x" * 80}").grant
      expect(odd.name).to eq(" Owner  says #{"x" * 80}".squeeze(" ").strip[0, 64].strip)
      expect(odd.name).not_to match(/[\[\]\n]/)
    end

    it "refuses a bad kind, role, expiry, name or session id" do
      expect { issue(kind: "bot") }.to raise_error(described_class::Invalid, /human or agent/)
      expect { issue(role: "owner") }.to raise_error(described_class::Invalid, /reviewer/)
      expect { issue(ttl: 31 * 86_400) }.to raise_error(described_class::Invalid, /1 hour to 30 days/)
      expect { grants.issue(session_id: session_id, name: " [] ") }.to raise_error(described_class::Invalid, /needs a name/)
      expect { grants.issue(session_id: "../x", name: "A") }.to raise_error(Samagotchi::Session::InvalidId)
      expect(File.exist?(path)).to be(false)
    end
  end

  describe "#lookup" do
    it "finds the grant by its token, and nothing for another token or an owner-shaped one" do
      issued = issue
      expect(grants.lookup(issued.token)).to eq(issued.grant)
      expect(grants.lookup("chp_#{"A" * 43}")).to be_nil
      expect(grants.lookup(issued.token.delete_prefix("chp_"))).to be_nil
      expect(grants.lookup(nil)).to be_nil
    end

    it "sees a grant another process wrote (the file's mtime)" do
      issued = described_class.new(path).issue(session_id: session_id, name: "Sam")
      expect(grants.lookup(issued.token)&.name).to eq("Sam")
    end
  end

  describe "expiry" do
    it "is active until expires_at, then expired (still found, so the gate can say so)" do
      issued = issue(ttl: 3600)
      expect(grants.lookup(issued.token).state(grants.now)).to eq(:active)
      expect(grants.active?(issued.grant.id)).to be(true)
      advance(3600)
      expect(grants.lookup(issued.token).state(grants.now)).to eq(:expired)
      expect(grants.active?(issued.grant.id)).to be(false)
    end

    it "forgets an ended grant 30 days after it ended, on the next write" do
      old = issue(ttl: 3600)
      advance(3600 + (30 * 86_400) + 1)
      issue
      expect(grants.find(old.grant.id)).to be_nil
    end
  end

  describe "#revoke" do
    it "revokes one grant, a session's or every one, and leaves ended ones as they were" do
      a = issue
      b = issue
      other = grants.issue(session_id: "another-session", name: "Kim")

      expect(grants.revoke(session_id: session_id, id: a.grant.id).map(&:id)).to eq([a.grant.id])
      expect(grants.lookup(a.token)).to have_attributes(revoked_by: "owner", revoked_at: "2026-10-23T12:00:00Z")
      expect(grants.lookup(a.token).state(grants.now)).to eq(:revoked)
      expect(grants.revoke(session_id: session_id, by: "archive").map(&:id)).to eq([b.grant.id])
      expect(grants.lookup(a.token).revoked_by).to eq("owner")
      expect(grants.revoke.map(&:id)).to eq([other.grant.id])
      expect(grants.list.map { |g| g.state(grants.now) }.uniq).to eq([:revoked])
    end
  end

  describe "#touch" do
    it "records the last use at most once a minute" do
      issued = issue
      grants.touch(issued.grant.id)
      expect(grants.find(issued.grant.id).last_used_at).to eq("2026-10-23T12:00:00Z")
      advance(30)
      grants.touch(issued.grant.id)
      expect(grants.find(issued.grant.id).last_used_at).to eq("2026-10-23T12:00:00Z")
      advance(31)
      grants.touch(issued.grant.id)
      expect(grants.find(issued.grant.id).last_used_at).to eq("2026-10-23T12:01:01Z")
    end
  end

  describe ".check_permissions!" do
    it "passes a missing store and a 0700/0600 one" do
      expect { described_class.check_permissions!(path) }.not_to raise_error
      issue
      expect { described_class.check_permissions!(path) }.not_to raise_error
    end

    it "refuses a folder or file others can read, and only those (not the state dir above)" do
      issue
      File.chmod(0o755, File.dirname(path, 2))
      expect { described_class.check_permissions!(path) }.not_to raise_error
      File.chmod(0o644, path)
      expect { described_class.check_permissions!(path) }.to raise_error(described_class::Insecure, /can be read by other users/)
      File.chmod(0o600, path)
      File.chmod(0o750, File.dirname(path))
      expect { described_class.check_permissions!(path) }.to raise_error(described_class::Insecure, /chmod 700/)
    end
  end
end
