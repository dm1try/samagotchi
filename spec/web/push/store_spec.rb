# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/push/store"
require_relative "../../support/web_push_receiver"

RSpec.describe Samagotchi::Web::Push::Store do
  let(:root) { Dir.mktmpdir("push-store-spec") }
  let(:dir) { File.join(root, "web-push") }
  let(:now) { Time.utc(2026, 10, 24, 12) }
  let(:store) { described_class.new(dir, clock: -> { now }) }
  let(:origin) { "https://studio.example.ts.net" }
  let(:receiver) { WebPushReceiver.new }
  let(:endpoint) { "https://web.push.apple.com/QGabc123" }

  after { FileUtils.rm_rf(root) }

  def mode(path) = File.stat(path).mode & 0o777

  it "lives next to the grants, beside the sessions dir" do
    expect(described_class.dir(state_dir: "/x/samagotchi/sessions")).to eq("/x/samagotchi/web-push")
  end

  describe "#vapid_key" do
    it "is made once, 0600 in a 0700 folder, and read back" do
      key = store.vapid_key
      expect(mode(dir)).to eq(0o700)
      expect(mode(store.key_path)).to eq(0o600)
      again = described_class.new(dir).vapid_key
      expect(Samagotchi::Web::Push::Crypto.public_key_b64(again)).to eq(Samagotchi::Web::Push::Crypto.public_key_b64(key))
    end
  end

  describe "#add / #remove" do
    it "keeps a subscription (0600) with its short id, origin and label, and never shows its endpoint or keys" do
      sub = store.add(receiver.subscription(endpoint), origin: origin, label: "iPhone · 2026-10-24")

      expect(sub.id).to eq(Digest::SHA256.hexdigest(endpoint)[0, 8])
      expect(sub.id).to match(/\A\h{8}\z/)
      expect(mode(store.subs_path)).to eq(0o600)
      expect(store.subscriptions.map(&:id)).to eq([sub.id])
      expect(store.subscriptions.first.p256dh_bytes).to eq(receiver.p256dh)
      expect(store.subscriptions.first.created_at).to eq("2026-10-24T12:00:00Z")
      expect(sub.public_h.to_s).not_to include(endpoint)
      expect(sub.public_h.to_s).not_to include(sub.p256dh)
      expect(sub.inspect).not_to include(endpoint)
    end

    it "replaces the same endpoint, keeps others, and removes by id or endpoint" do
      store.add(receiver.subscription(endpoint), origin: origin, label: "old")
      store.add(receiver.subscription(endpoint), origin: origin, label: "new")
      other = store.add(WebPushReceiver.new.subscription("https://fcm.googleapis.com/fcm/send/x"), origin: origin, label: "b")
      expect(store.subscriptions.map(&:label)).to eq(%w[new b])

      expect(store.remove(other.id)&.label).to eq("b")
      expect(store.remove(endpoint)&.label).to eq("new")
      expect(store.remove("nothing")).to be_nil
      expect(store.subscriptions).to eq([])
    end

    it "removes by id or endpoint only on the origin given (#remove), any origin without one" do
      far = store.add(receiver.subscription(endpoint), origin: "https://old.example", label: "far")
      expect(store.remove(endpoint, origin: origin)).to be_nil
      expect(store.remove(far.id, origin: origin)).to be_nil
      expect(store.remove(endpoint, origin: "https://old.example")&.label).to eq("far")
      expect(store.subscriptions).to eq([])
    end

    it "removes a device by id only on the origin given (#remove_device)" do
      far = store.add(receiver.subscription(endpoint), origin: "https://old.example", label: "far")
      expect(store.remove_device(far.id, origin: origin)).to be_nil
      expect(store.remove_device(endpoint, origin: nil)).to be_nil
      expect(store.remove_device(far.id)&.label).to eq("far")
      expect(store.subscriptions).to eq([])
    end

    it "drops the entry it replaces (the device's id before, on this origin), never itself, and yields it" do
      dead = store.add(receiver.subscription("#{endpoint}dead"), origin: origin, label: "dead")
      elsewhere = store.add(WebPushReceiver.new.subscription("#{endpoint}far"), origin: "https://old.example", label: "far")
      yielded = []
      fresh = store.add(WebPushReceiver.new.subscription("#{endpoint}new"), origin: origin, label: "new",
                                                                            replaces: dead.id) { |gone| yielded << gone.id }
      expect(yielded).to eq([dead.id])
      expect(store.subscriptions.map(&:label)).to eq(%w[far new])

      # The same endpoint again names itself: kept, nothing yielded.
      store.add(WebPushReceiver.new.subscription("#{endpoint}new"), origin: origin, label: "again",
                                                                    replaces: fresh.id) { |gone| yielded << gone.id }
      # Another origin's id, an unknown one and a non-string are ignored.
      [elsewhere.id, "deadbeef", 42].each do |id|
        store.add(WebPushReceiver.new.subscription("#{endpoint}new"), origin: origin, label: "again", replaces: id) { |gone| yielded << gone.id }
      end
      expect(yielded).to eq([dead.id])
      expect(store.subscriptions.map(&:label)).to eq(%w[far again])
    end

    it "lists by origin" do
      store.add(receiver.subscription(endpoint), origin: origin, label: "a")
      expect(store.for_origin(origin).size).to eq(1)
      expect(store.for_origin("https://renamed.example.ts.net")).to eq([])
    end

    it "takes a host under a .suffix service, not the bare suffix" do
      ok = WebPushReceiver.new.subscription("https://wns2-par02p.notify.windows.com/w/?token=x")
      expect(store.add(ok, origin: origin, label: "w").label).to eq("w")
      expect { store.add(WebPushReceiver.new.subscription("https://evilnotify.windows.com/x"), origin: origin, label: "x") }
        .to raise_error(described_class::Invalid, /only pushes to the browsers' push services/)
    end

    it "refuses a bad endpoint or keys with one message each" do
      sub = receiver.subscription(endpoint)
      refusals = {
        nil => /needs an endpoint and keys/,
        { "endpoint" => endpoint } => /needs an endpoint and keys/,
        sub.merge("endpoint" => "http://web.push.apple.com/x") => /must be an https URL on port 443/,
        sub.merge("endpoint" => "https://web.push.apple.com:8443/x") => /must be an https URL on port 443/,
        sub.merge("endpoint" => "https://u:p@web.push.apple.com/x") => /must be an https URL on port 443/,
        sub.merge("endpoint" => "https://169.254.169.254/latest") => /not 169\.254\.169\.254/,
        sub.merge("endpoint" => "https://web.push.apple.com.evil.example/x") => /push services/,
        sub.merge("keys" => sub["keys"].merge("p256dh" => "AAAA")) => /p256dh must be a P-256 public key/,
        sub.merge("keys" => sub["keys"].merge("p256dh" => "!!")) => /p256dh must be a P-256 public key/,
        sub.merge("keys" => sub["keys"].merge("p256dh" => WebPushReceiver::OFF_CURVE)) => /p256dh is not a point on P-256/,
        sub.merge("keys" => sub["keys"].merge("auth" => Samagotchi::Web::Push::Crypto.b64u("x" * 15))) => /auth must be 16 bytes/
      }
      refusals.each do |given, message|
        expect { store.add(given, origin: origin, label: "x") }.to raise_error(described_class::Invalid, message)
      end
      expect(store.subscriptions).to eq([])
    end
  end

  it "keeps at most MAX_SUBS devices, and never shows its key" do
    stub_const("#{described_class}::MAX_SUBS", 2)
    store.add(receiver.subscription("#{endpoint}1"), origin: origin, label: "a")
    store.add(receiver.subscription("#{endpoint}2"), origin: origin, label: "b")
    store.add(receiver.subscription("#{endpoint}2"), origin: origin, label: "b again")
    expect { store.add(receiver.subscription("#{endpoint}3"), origin: origin, label: "c") }
      .to raise_error(described_class::Invalid, "chi web already pushes to 2 devices: turn the bell off on one first")
    # The entry it replaces doesn't count: a full store takes its device back.
    b = store.find(described_class.short_id("#{endpoint}2"))
    expect(store.add(receiver.subscription("#{endpoint}3"), origin: origin, label: "c", replaces: b.id).label).to eq("c")
    store.vapid_key
    expect(store.inspect).to eq("#<#{described_class} #{dir}>")
  end

  describe "#mark" do
    it "stamps a delivery, or keeps its error" do
      sub = store.add(receiver.subscription(endpoint), origin: origin, label: "a")
      store.mark(sub.id, error: "500")
      expect(store.find(sub.id).last_error).to eq("500")
      store.mark(sub.id, ok: true)
      expect(store.find(sub.id)).to have_attributes(last_ok_at: "2026-10-24T12:00:00Z", last_error: nil)
    end
  end

  describe "a corrupt file" do
    it "lists nothing and is never written over" do
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.write(store.subs_path, "{not json")
      expect(store.subscriptions).to eq([])
      expect { store.add(receiver.subscription(endpoint), origin: origin, label: "a") }
        .to raise_error(described_class::Corrupt, /won't write over it/)
      expect(File.read(store.subs_path)).to eq("{not json")
    end
  end

  describe "#check_permissions!" do
    it "passes a missing store and a made one, and refuses a folder or file others can read" do
      expect { store.check_permissions! }.not_to raise_error
      store.vapid_key
      store.add(receiver.subscription(endpoint), origin: origin, label: "a")
      expect { store.check_permissions! }.not_to raise_error

      File.chmod(0o644, store.key_path)
      expect { store.check_permissions! }
        .to raise_error(described_class::Insecure, /vapid\.pem can be read by other users: chmod 700 .* \(it holds chi's push key and devices\)/)
      File.chmod(0o600, store.key_path)
      store.mark_sent("s1:q1")
      File.chmod(0o644, store.sent_path)
      expect { store.check_permissions! }.to raise_error(described_class::Insecure, /sent\.json can be read by other users/)
      File.chmod(0o600, store.sent_path)
      File.chmod(0o755, dir)
      expect { store.check_permissions! }.to raise_error(described_class::Insecure, /web-push can be read by other users/)
    end
  end

  describe "the handled keys (sent.json)" do
    it "records a key with its time, 0600, and drops keys older than a day on each write" do
      expect(store.sent_keys).to eq({})
      store.mark_sent("s1:q1")
      expect(store.sent_keys).to eq("s1:q1" => "2026-10-24T12:00:00Z")
      expect(mode(store.sent_path)).to eq(0o600)
      expect(JSON.parse(File.read(store.sent_path))["version"]).to eq(1)

      later = described_class.new(dir, clock: -> { now + (24 * 3600) + 1 })
      later.mark_sent("s2:q2")
      expect(store.sent_keys.keys).to eq(["s2:q2"])
    end

    it "reads a corrupt one as none, logs it once, and rewrites it on the next write" do
      allow(Samagotchi::Log).to receive(:warn)
      FileUtils.mkdir_p(dir)
      File.write(store.sent_path, "{nope")
      expect(store.sent_keys).to eq({})
      File.write(store.sent_path, JSON.generate({ "version" => 1, "keys" => ["s1:q1"] }))
      expect(store.sent_keys).to eq({})
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "push_sent_corrupt", path: store.sent_path).once

      store.mark_sent("s1:q1")
      expect(store.sent_keys.keys).to eq(["s1:q1"])
    end

    it "drops a key whose time doesn't read" do
      FileUtils.mkdir_p(dir)
      File.write(store.sent_path, JSON.generate({ "version" => 1, "keys" => { "old:q" => "yesterday" } }))
      store.mark_sent("s1:q1")
      expect(store.sent_keys.keys).to eq(["s1:q1"])
    end
  end

  describe "#set_prefs" do
    it "sets a device's done pref, on its origin only, and answers it (nil for none)" do
      sub = store.add(receiver.subscription(endpoint), origin: origin, label: "a")
      expect(sub.public_h[:prefs]).to eq(done: false)
      expect(store.set_prefs(sub.id, done: true, origin: "https://other.example")).to be_nil
      expect(store.set_prefs(sub.id, done: true, origin: origin)).to have_attributes(id: sub.id, done?: true)
      expect(store.find(sub.id).public_h[:prefs]).to eq(done: true)
      expect(store.set_prefs(sub.id, done: false).done?).to be(false)
      expect(store.set_prefs("ffffffff", done: true)).to be_nil
    end
  end
end
