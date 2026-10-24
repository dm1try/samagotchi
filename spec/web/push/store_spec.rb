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
      File.chmod(0o755, dir)
      expect { store.check_permissions! }.to raise_error(described_class::Insecure, /web-push can be read by other users/)
    end
  end
end
