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

  describe "#issue bound to an identity" do
    it "keeps the identity lower case, shows it, and writes store version 2" do
      grant = issue(identity: "  Alex@Corp.Example ").grant
      expect(grant.identity).to eq("alex@corp.example")
      expect(grant.public_h(now.first)).to include(identity: "alex@corp.example")
      expect(JSON.parse(File.read(path))).to include("version" => 2)
      expect(JSON.parse(File.read(path))["grants"].first).to include("identity" => "alex@corp.example")
      expect(grants.find(grant.id).identity).to eq("alex@corp.example")
    end

    it "takes a login with a dot-less domain (Tailscale's alex@github)" do
      expect(issue(identity: "alex@github").grant.identity).to eq("alex@github")
    end

    it "refuses anything that isn't one address, writing nothing" do
      ["", "  ", "alex", "@corp", "alex@", "a@b@c", "a b@c", "a,b@c", "<a@b>", "\"a\"@b", "a\u0000@b", "a\tb@c",
       "#{"x" * 250}@corp", "al\u00e9x@corp", "alex@b\u00fccher.de", 42, ["a@b"]].each do |bad|
        expect { issue(identity: bad) }.to raise_error(described_class::BadIdentity, /bound to one email address/), bad.inspect
      end
      expect(File.exist?(path)).to be(false)
    end

    it "is unbound without one: nil in the view, no key in the store, version 1" do
      grant = issue.grant
      expect(grant.public_h(now.first)).to include(identity: nil)
      expect(JSON.parse(File.read(path))).to include("version" => 1)
      expect(JSON.parse(File.read(path))["grants"].first).not_to have_key("identity")
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

  # L-P5: a store that doesn't read is never written over (the next invite
  # would keep only its own grant and lose every other digest); its grants
  # find nothing (fail closed), and the owner's writes are refused with one
  # error naming the file.
  describe "a store that can't be read" do
    def corrupt!(body)
      issue
      File.write(path, body)
    end

    shared_examples "fails closed and keeps the file" do
      it "finds no grant, logs it once, and refuses issue, set_cap, revoke and list without touching the file" do
        before = File.binread(path)
        allow(Samagotchi::Log).to receive(:warn)
        expect(grants.lookup(token)).to be_nil
        expect(grants.find("p_00000000")).to be_nil
        expect(grants.active?("p_00000000")).to be(false)
        expect(Samagotchi::Log).to have_received(:warn).with(:web, "grants_unreadable", hash_including(path: path)).once

        [-> { issue }, -> { grants.set_cap("p_00000000", 3) }, -> { grants.revoke }, -> { grants.list }].each do |call|
          expect(&call).to raise_error(described_class::Corrupt, /#{Regexp.escape(path)} can't be read .*won't write over it/)
        end
        expect { grants.touch("p_00000000") }.not_to raise_error
        expect(File.binread(path)).to eq(before)
      end
    end

    let(:token) { "chp_whatever" }

    context "when it isn't JSON" do
      before { corrupt!("{\"version\": 1, \"grants\": [") }

      it_behaves_like "fails closed and keeps the file"
    end

    context "when a grant's identity isn't one #issue would store (it could read as unbound)" do
      before do
        issue
        data = JSON.parse(File.read(path))
        [false, "", ["a@b"], "Alex@Corp", " a@b"].each_with_index do |bad, i|
          data["grants"] << data["grants"].first.merge("id" => "p_0000000#{i}", "identity" => bad)
        end
        File.write(path, JSON.generate(data))
      end

      it_behaves_like "fails closed and keeps the file"

      it "names the bad identity" do
        allow(Samagotchi::Log).to receive(:warn)
        expect { grants.list }.to raise_error(described_class::Corrupt, /grant 2 has a bad identity/)
      end
    end

    context "when a grant lacks its digest or expiry (no 500 for every participant)" do
      before do
        issue
        data = JSON.parse(File.read(path))
        data["grants"] << data["grants"].first.merge("id" => "p_00000000", "digest" => nil)
        data["grants"] << data["grants"].first.merge("id" => "p_00000001", "expires_at" => "soon")
        File.write(path, JSON.generate(data))
      end

      it_behaves_like "fails closed and keeps the file"
    end

    it "reads again once the file is fixed" do
      issued = issue
      good = File.read(path)
      File.write(path, "nope")
      allow(Samagotchi::Log).to receive(:warn)
      expect(grants.lookup(issued.token)).to be_nil
      File.write(path, good)
      expect(grants.lookup(issued.token)&.id).to eq(issued.grant.id)
      expect { issue }.not_to raise_error
    end
  end

  describe "the store's version" do
    def stored = JSON.parse(File.read(path))

    def rewrite!
      data = stored
      yield data
      File.write(path, JSON.generate(data))
    end

    it "is 1 while no grant is bound, 2 once one is" do
      issued = issue
      expect(stored["version"]).to eq(1)
      expect(stored["grants"].first).not_to have_key("identity")

      rewrite! { |data| data["grants"].first["identity"] = "alex@corp.example" }
      grants.revoke(id: issued.grant.id)
      expect(stored).to include("version" => 2)
      expect(stored["grants"].first).to include("identity" => "alex@corp.example", "revoked_by" => "owner")
    end

    it "keeps a grant's keys it doesn't know on a rewrite, and never shows them" do
      issued = issue
      rewrite! { |data| data["grants"].first["exposure"] = { "plan" => true } }
      grants.set_cap(issued.grant.id, 5)
      grants.revoke(id: issued.grant.id)

      row = stored["grants"].first
      expect(row).to include("exposure" => { "plan" => true }, "cap" => 5.0, "revoked_by" => "owner")
      expect(grants.find(issued.grant.id).public_h(now.first)).not_to have_key(:exposure)
    end

    it "never goes back to 1 once a store says 2" do
      issue
      rewrite! { |data| data["version"] = 2 }
      issue
      expect(stored["version"]).to eq(2)
    end

    context "when a newer chi wrote it" do
      let!(:issued) { issue }

      before { rewrite! { |data| data["version"] = 3 } }

      it "leaves out a grant with fields this chi doesn't know (they may restrict it), keeps the others" do
        other = described_class.new(path, clock: -> { now.first })
        rewrite! do |data|
          data["version"] = 2
          data["grants"].first["bound_to"] = { "who" => "alex@corp" }
        end
        plain = other.issue(session_id: session_id, name: "Sam")
        rewrite! { |data| data["version"] = 3 }
        expect(grants.lookup(issued.token)).to be_nil
        expect(grants.active?(issued.grant.id)).to be(false)
        expect(grants.lookup(plain.token)&.id).to eq(plain.grant.id)
        expect(grants.list.map(&:id)).to eq([plain.grant.id])
      end

      it "still finds its grants, and refuses every write without touching the file" do
        before = File.binread(path)
        expect(grants.lookup(issued.token)&.id).to eq(issued.grant.id)
        expect(grants.list.map(&:id)).to eq([issued.grant.id])

        [-> { issue }, -> { grants.set_cap(issued.grant.id, 3) }, -> { grants.revoke }].each do |call|
          expect(&call).to raise_error(described_class::Newer, /newer chi \(grants store version 3; this chi knows up to 2\): chi won't write over it/)
        end
        expect { grants.touch(issued.grant.id) }.not_to raise_error
        expect(File.binread(path)).to eq(before)
      end
    end

    it "refuses a version that isn't a number as a store that doesn't read" do
      issue
      rewrite! { |data| data["version"] = "2" }
      allow(Samagotchi::Log).to receive(:warn)
      expect { grants.list }.to raise_error(described_class::Corrupt, /a bad version/)
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
