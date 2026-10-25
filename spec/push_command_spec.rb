# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/push_command"
require_relative "support/web_push_receiver"

# chi web push ls|rm|test on a temp store, with a fake client: what it
# prints (never an endpoint or keys), stale marking, removing, the test
# push and a gone device.
RSpec.describe Samagotchi::PushCommand do
  let(:root) { Dir.mktmpdir("push-command") }
  let(:store) { Samagotchi::Web::Push::Store.new(File.join(root, "web-push"), clock: -> { Time.utc(2026, 10, 24, 12) }) }
  let(:origin) { "https://studio.example.ts.net" }
  let(:current) { origin }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:results) { Hash.new { Samagotchi::Web::Push::Client::Result.new(status: :ok, code: 201, ms: 7) } }
  let(:sent) { [] }
  let(:client) do
    log = sent
    answers = results
    lambda do |sub|
      fake = Object.new
      fake.define_singleton_method(:deliver) do |target, payload, ttl:, urgency:|
        log << [sub.id, target.id, payload, ttl, urgency]
        answers[target.id]
      end
      fake
    end
  end
  let(:phone_endpoint) { "https://web.push.apple.com/QGphone" }
  let!(:phone) { store.add(WebPushReceiver.new.subscription(phone_endpoint), origin: origin, label: "iPhone · 2026-10-24") }
  let!(:old) do
    store.add(WebPushReceiver.new.subscription("https://web.push.apple.com/QGold"), origin: "https://old.example.ts.net",
                                                                                    label: "iPad · 2026-09-01")
  end

  after { FileUtils.rm_rf(root) }

  def run(*argv)
    described_class.new(argv, stdout: out, stderr: err, store: store, origin: -> { current }, client: client).run
  end

  describe "ls" do
    it "lists every device with its short id, label, origin and done, the other origin's stale; never an endpoint or keys" do
      store.set_prefs(phone.id, done: true)
      expect(run("ls")).to eq(0), err.string
      lines = out.string.lines
      expect(lines.first.split).to eq(%w[ID LABEL ORIGIN ADDED LAST OK DONE NOTE])
      expect(lines[1]).to start_with(phone.id).and include("iPhone · 2026-10-24", origin, "never", "on")
      expect(lines[1]).not_to include("stale")
      expect(lines[2]).to start_with(old.id).and include("https://old.example.ts.net", "off", "stale")
      store.subscriptions.each do |sub|
        expect(out.string).not_to include(sub.endpoint, sub.p256dh, sub.auth)
      end
    end

    it "marks none stale when no chi web runs and no web.public_url is set" do
      allow(Samagotchi::Web::Running).to receive(:live_public_url).and_return(nil)
      described_class.new(%w[ls --format json], stdout: out, stderr: err, store: store, client: client).run
      expect(JSON.parse(out.string).map { |d| d["stale"] }).to eq([false, false])
    end

    it "answers JSON without endpoints, and says when there are no devices" do
      run("ls", "--format", "json")
      rows = JSON.parse(out.string)
      expect(rows.map { |d| [d["id"], d["stale"], d["prefs"]] }).to eq([[phone.id, false, { "done" => false }], [old.id, true, { "done" => false }]])
      expect(rows.flat_map(&:keys).uniq).not_to include("endpoint", "keys")

      store.remove(phone.id)
      store.remove(old.id)
      out.truncate(0)
      out.rewind
      expect(run("ls")).to eq(0)
      expect(out.string).to eq("no devices (turn the bell on in the phone's Home Screen app)\n")
    end

    it "refuses a store others can read (exit 1) and a corrupt one" do
      File.chmod(0o644, store.subs_path)
      expect(run("ls")).to eq(1)
      expect(err.string).to include("chi web push ls: ", "can be read by other users")
      File.chmod(0o600, store.subs_path)
      File.write(store.subs_path, "nope")
      expect(run("ls")).to eq(1)
      expect(err.string).to include("can't be read (not JSON)")
    end
  end

  describe "rm" do
    it "removes a device by id, and refuses an unknown one (exit 1)" do
      expect(run("rm", old.id)).to eq(0)
      expect(out.string).to eq("#{old.id}  iPad · 2026-09-01  removed\n")
      expect(store.subscriptions.map(&:id)).to eq([phone.id])
      expect(run("rm", old.id)).to eq(1)
      expect(err.string).to eq("chi web push rm: no device #{old.id} (chi web push ls)\n")
      expect(run("rm", phone_endpoint)).to eq(1)
      expect(store.subscriptions.map(&:id)).to eq([phone.id])
    end

    it "is a usage error without exactly one id (exit 2)" do
      expect(run("rm")).to eq(2)
      expect(run("rm", "a", "b")).to eq(2)
      expect(run("bogus")).to eq(2)
      expect(err.string).to include("chi web push: unknown subcommand bogus")
    end
  end

  describe "test" do
    it "pushes the test notification to every device not stale, and stamps its delivery" do
      expect(run("test")).to eq(0), err.string
      expect(sent.map { |s| s.values_at(1, 3, 4) }).to eq([[phone.id, 600, "high"]])
      expect(sent.first[2]).to include(kind: "show", tag: "chi:test", body: "test notification")
      expect(out.string).to eq("#{phone.id}  iPhone · 2026-10-24  ok 201 (7 ms)\n")
      expect(store.find(phone.id).last_ok_at).to eq("2026-10-24T12:00:00Z")
    end

    it "pushes to the device named, a stale one too" do
      expect(run("test", old.id)).to eq(0)
      expect(sent.map { |s| s[1] }).to eq([old.id])
      expect(run("test", "abcdef12")).to eq(1)
      expect(err.string).to include("no device abcdef12")
    end

    it "removes a device its push service no longer knows, and exits 1 on a failure" do
      results[phone.id] = Samagotchi::Web::Push::Client::Result.new(status: :gone, code: 410, ms: 5)
      results[old.id] = Samagotchi::Web::Push::Client::Result.new(status: :failed, code: 500, ms: 9)
      allow(Samagotchi::Web::Running).to receive(:live_public_url).and_return(nil)
      code = described_class.new(%w[test], stdout: out, stderr: err, store: store, origin: -> {}, client: client).run
      expect(code).to eq(1)
      expect(out.string.lines).to eq(["#{phone.id}  iPhone · 2026-10-24  gone 410 (5 ms): removed (the push service no longer knows it)\n",
                                      "#{old.id}  iPad · 2026-09-01  failed 500 (9 ms)\n"])
      expect(store.subscriptions.map(&:id)).to eq([old.id])
      expect(store.find(old.id).last_error).to eq("500")
    end

    it "says so when there is no device to push to" do
      store.remove(phone.id)
      expect(run("test")).to eq(1)
      expect(err.string).to eq("chi web push test: no device to push to (chi web push ls)\n")
    end
  end
end
