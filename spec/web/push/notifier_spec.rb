# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/session_hub"
require "samagotchi/web/push/client"
require "samagotchi/web/push/crypto"
require "samagotchi/web/push/notifier"
require "samagotchi/web/push/presence"
require "samagotchi/web/push/store"
require_relative "../../support/web_push_receiver"

# Hub events in, a fake client's calls out. The specs drive the sender with
# #pump and move the clock; one example runs the real thread.
RSpec.describe Samagotchi::Web::Push::Notifier do
  let(:root) { Dir.mktmpdir("push-notifier-spec") }
  let(:origin) { "https://studio.example.ts.net" }
  let(:store) { Samagotchi::Web::Push::Store.new(File.join(root, "web-push")) }
  let(:clock) { [100.0] }
  let(:client) { PushNotifierSpecClient.new }
  let(:presence) { Samagotchi::Web::Push::Presence.new(now: -> { clock[0] }) }
  let(:notifier) { described_class.new(store: store, client: client, origin: origin, presence: presence, now: -> { clock[0] }) }
  let!(:phone) { store.add(WebPushReceiver.new.subscription("https://web.push.apple.com/phone"), origin: origin, label: "iPhone") }

  # Records each delivery; answers the next of +script+, else +status+.
  # :busy is a 429 with Retry-After 2, :error a 500 without one (10 s).
  class PushNotifierSpecClient
    Result = Samagotchi::Web::Push::Client::Result
    CODES = { ok: 201, gone: 410, bad_jwt: 403, failed: 500, busy: 429, error: 500 }.freeze

    attr_reader :calls
    attr_accessor :status, :script

    def initialize
      @calls = []
      @status = :ok
      @script = []
    end

    def deliver(sub, payload, ttl:, urgency:)
      @calls << { sub: sub.id, payload: payload, ttl: ttl, urgency: urgency }
      answer = script.shift || status
      failed = %i[failed busy error].include?(answer)
      Result.new(status: failed ? :failed : answer, code: CODES[answer], ms: 3, error: failed ? CODES[answer].to_s : nil,
                 retry_after: { busy: 2, error: 10 }[answer])
    end
  end

  # A hub stand-in: subscribe(sink, snapshot: true) → [handle, summaries].
  class PushNotifierSpecHub
    attr_reader :sinks

    def initialize(summaries = [])
      @summaries = summaries
      @sinks = []
    end

    def subscribe(sink, snapshot:)
      raise "the notifier seeds from the snapshot" unless snapshot

      @sinks << sink
      [Struct.new(:hub, :sink) { def unsubscribe = hub.sinks.delete(sink) }.new(self, sink), @summaries]
    end
  end

  after do
    notifier.stop
    FileUtils.rm_rf(root)
    expect(client.calls.map { |c| c[:payload][:kind] }.uniq - ["show"]).to eq([])
  end

  def summary(id: "s1", question: nil, parent_id: nil, title: "fix the build", card: nil, turn: nil, project_root: nil)
    { id: id, title: title, first_preview: "first", parent_id: parent_id, pending_question: question, pending_card: card,
      last_turn: turn, project_root: project_root }.compact
  end

  # A last_turn as the summary has it (string keys).
  def ended(outcome, seconds, at: "2026-10-25T09:05:12.345+02:00", origin: "client")
    { "outcome" => outcome, "ended_at" => at, "seconds" => seconds, "origin" => origin }
  end

  # A second device on this origin with prefs.done.
  def add_done_device
    sub = store.add(WebPushReceiver.new.subscription("https://web.push.apple.com/done"), origin: origin, label: "iPad")
    store.set_prefs(sub.id, done: true)
  end

  def hub_event(**) = Samagotchi::Web::SessionHub::Event.new(**)

  def session(**kw) = notifier.call(hub_event(type: "session", seq: 1, data: { session: summary(**kw) }))

  def update(version, blocked: nil)
    notifier.call(hub_event(type: "chi", seq: 2,
                            data: { version: Samagotchi::VERSION, installed: nil, available: version,
                                    update_blocked: blocked, update_notice: true }))
  end

  def advance(seconds)
    clock[0] += seconds
    notifier.pump
  end

  def kinds = client.calls.map { |c| c[:payload][:kind] }

  # Every push shows a notification (WebKit's silent-push quota): whatever
  # an example did, the client only ever got shows.

  context "when started on a hub" do
    before { notifier.start(PushNotifierSpecHub.new, sender: false) }

    it "pushes a newly available chi once with a 24-hour TTL and normal urgency" do
      update("0.19.0")
      advance(3)
      update("0.19.0")
      advance(3)

      expect(client.calls.map { |call| call.values_at(:ttl, :urgency, :payload) }).to eq([
        [24 * 3600, "normal", { v: 1, kind: "show", tag: "chi:update:0.19.0",
                                title: "chi 0.19.0 is available", body: "Run chi update to install it.",
                                url: "/", badge: 0, open: [] }]
      ])
      expect(store.sent_keys.keys).to eq(["chi:update:0.19.0"])
    end

    it "sends a blocked install to the page for its own command instead of chi update" do
      update("0.19.0", blocked: "bundler")
      advance(3)

      expect(client.calls.map { |call| call[:payload][:body] }).to eq(["Open chi web for how to update this install."])
    end

    it "skips an update push while a chi web page is in front and marks it handled" do
      presence.report("desk", true)
      update("0.19.0")
      advance(3)

      expect(client.calls).to be_empty
      expect(store.sent_keys.keys).to eq(["chi:update:0.19.0"])
    end

    it "pushes a new approval once, after the 3 s hold, with the in-tab words, the session's url and the badge" do
      session(question: { id: "q1", kind: "approval" })
      advance(2.9)
      expect(client.calls).to eq([])
      advance(0.2)
      session(question: { id: "q1", kind: "approval" })
      advance(5)

      expect(client.calls).to eq([{ sub: phone.id, ttl: 12 * 3600, urgency: "high",
                                    payload: { v: 1, kind: "show", tag: "s1:q1", title: "fix the build",
                                               body: "needs approval", url: "/?scope=all#/s/s1", badge: 1, open: ["s1:q1"] } }])
      expect(store.find(phone.id).last_ok_at).not_to be_nil
    end

    it "opens a session in a repo in its own project's view, the folder encoded" do
      session(id: "r1", question: { id: "q1", kind: "question" }, project_root: "/Users/me/my app&co")
      advance(5)

      expect(client.calls.map { |c| c[:payload][:url] }).to eq(["/?dir=/Users/me/my+app%26co#/s/r1"])
    end

    context "with a chi web page in front (presence)" do
      it "sends nothing, logs the skip without a device, and never pushes that key later" do
        allow(Samagotchi::Log).to receive(:info).and_call_original
        presence.report("desk", true)
        session(question: { id: "q1", kind: "approval" })
        session(id: "f", turn: ended("failed", 2))
        advance(3)
        presence.report("desk", false)
        session(question: { id: "q1", kind: "approval" })
        advance(10)
        expect(client.calls).to eq([])
        expect(Samagotchi::Log).to have_received(:info).with(:web, "push_skipped", { reason: "present", kind: "approval" })
        expect(Samagotchi::Log).to have_received(:info).with(:web, "push_skipped", { reason: "present", kind: "failed" })
      end

      it "pushes once the page's report is older than 45 s" do
        presence.report("desk", true)
        advance(43)
        session(question: { id: "q1", kind: "approval" })
        advance(3)
        expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["s1:q1"])
      end

      it "pushes when the page said it went behind" do
        presence.report("desk", true)
        session(question: { id: "q1", kind: "approval" })
        advance(1)
        presence.report("desk", false)
        advance(2)
        expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["s1:q1"])
      end
    end

    it "pushes nothing when it is answered within the hold" do
      session(question: { id: "q1", kind: "approval" })
      advance(1)
      session
      advance(10)
      expect(client.calls).to eq([])
    end

    it "pushes nothing when a pushed one is answered anywhere (no close push)" do
      session(question: { id: "q1", kind: "question" })
      advance(3)
      session
      advance(10)

      expect(kinds).to eq(%w[show])
    end

    it "counts the open waiting ones in the badge and lists them in open" do
      session(id: "a", question: { id: "q1", kind: "approval" })
      session(id: "b", question: { id: "q2", kind: "approval" })
      advance(3)
      expect(client.calls.map { |c| c[:payload].values_at(:badge, :open) }).to eq([[2, %w[a:q1 b:q2]]] * 2)
    end

    it "leaves an answered one out of the next show's open list and badge" do
      session(id: "a", question: { id: "q1", kind: "approval" })
      advance(3)
      notifier.call(hub_event(type: "session", seq: 2, data: { session: summary(id: "a") }))
      session(id: "b", question: { id: "q2", kind: "approval" })
      advance(3)
      expect(client.calls.last[:payload]).to include(tag: "b:q2", open: ["b:q2"], badge: 1)
    end

    it "sends a show without open when the list would make it too long" do
      many = (1..80).map { |i| format("%08d-0000-4000-8000-%012d", i, i) }
      many.each { |id| session(id: id, question: { id: "q_#{id}", kind: "approval" }) }
      advance(3)
      last = client.calls.last[:payload]
      expect(last).not_to have_key(:open)
      expect(last[:badge]).to eq(80)
    end

    it "keeps the largest show it sends with open inside one Web Push record" do
      title = "😀" * 61
      ids = (1..60).map { |i| format("%08d-0000-4000-8000-%012d", i, i) }
      # One at a time, so each show's list is one longer, up to the limit and past it.
      ids.each do |id|
        session(id: id, title: title, question: { id: "q_#{id}_long_question_id", kind: "approval" })
        advance(3)
      end
      with_open = client.calls.map { |c| c[:payload] }.select { |p| p.key?(:open) }
      expect(with_open).not_to be_empty
      receiver = WebPushReceiver.new
      largest = with_open.map { |p| JSON.generate(p) }.max_by(&:bytesize)
      expect(largest.bytesize).to be > described_class::OPEN_LIMIT - 120
      expect(client.calls.last[:payload]).not_to have_key(:open)
      body = Samagotchi::Web::Push::Crypto.encrypt(largest, p256dh: receiver.p256dh, auth: receiver.auth)
      expect(body.bytesize).to be <= 4096
    end

    it "pushes nothing for one already relayed to its parent, nor when one is relayed after it was pushed" do
      session(id: "child", parent_id: "p", question: { id: "q1", kind: "approval", relayed_to: "p1234567" })
      advance(10)
      expect(client.calls).to eq([])

      session(id: "c2", question: { id: "q2", kind: "question" })
      advance(3)
      session(id: "c2", question: { id: "q2", kind: "question", relayed_to: "p1234567" })
      session(id: "c3", question: { id: "q3", kind: "question" })
      advance(3)
      expect(kinds).to eq(%w[show show])
      expect(client.calls.last[:payload][:open]).to eq(["c3:q3"])
    end

    it "holds a delegated child's approval 3.5 s, and a child's hook question too" do
      session(id: "child", parent_id: "p", question: { id: "q1", kind: "approval" })
      session(id: "hooked", parent_id: "p", question: { id: "h1", kind: "hook" })
      advance(3.4)
      expect(client.calls).to eq([])
      advance(0.1)
      expect(client.calls.map { |c| c[:payload][:tag] }).to contain_exactly("child:q1", "hooked:h1")
    end

    it "pushes a hook question as a question, a step-limit continue and a card, and badges them all" do
      session(id: "h", question: { id: "h1", kind: "hook" })
      session(id: "c", question: { id: "c1", kind: "continue" })
      session(id: "k", card: { id: "k1", bundle: "check-in" })
      advance(3)
      expect(client.calls.map { |c| c[:payload].values_at(:tag, :body, :badge) })
        .to eq([["h:h1", "needs an answer", 3], ["c:c1", "hit its step limit", 3], ["k:card:k1", "needs you", 3]])
      expect(client.calls.last[:payload][:open]).to eq(%w[h:h1 c:c1 k:card:k1])
      expect(client.calls.map { |c| c[:urgency] }.uniq).to eq(["high"])
    end

    it "pushes nothing for a card resolved within its hold" do
      session(id: "k", card: { id: "k1", bundle: "check-in" })
      advance(1)
      session(id: "k")
      advance(10)
      expect(client.calls).to eq([])
    end

    it "pushes a failed turn to every device, kept 10 min at normal urgency, outside the badge" do
      done_device = add_done_device
      session(id: "w", question: { id: "q1", kind: "approval" })
      advance(3)
      client.calls.clear
      session(id: "f", turn: ended("failed", 2))
      advance(3)
      expect(client.calls.map { |c| c.values_at(:sub, :ttl, :urgency) })
        .to eq([[phone.id, 600, "normal"], [done_device.id, 600, "normal"]])
      expect(client.calls.first[:payload]).to include(tag: "f:2026-10-25T09:05:12.345+02:00", body: "turn failed",
                                                      url: "/?scope=all#/s/f", badge: 1, open: ["w:q1"])
    end

    it "pushes a done turn only to a device that asked for done turns" do
      done_device = add_done_device
      session(id: "d", turn: ended("completed", 12.4))
      session(id: "short", turn: ended("completed", 3))
      advance(3)
      expect(client.calls.map { |c| [c[:sub], c[:payload][:body], c[:ttl]] }).to eq([[done_device.id, "done in 12 s", 600]])
    end

    it "pushes nothing on session_gone, and drops a show still in its hold" do
      session(question: { id: "q1", kind: "approval" })
      advance(3)
      session(id: "s2", question: { id: "q2", kind: "approval" })
      notifier.call(hub_event(type: "session_gone", seq: 3, data: { id: "s1" }))
      notifier.call(hub_event(type: "session_gone", seq: 4, data: { id: "s2" }))
      advance(10)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["s1:q1"])
    end

    it "sends only to this origin's devices and drops a gone one" do
      store.add(WebPushReceiver.new.subscription("https://web.push.apple.com/stale"), origin: "https://old.example.ts.net", label: "old")
      client.status = :gone
      session(question: { id: "q1", kind: "approval" })
      advance(3)
      expect(client.calls.map { |c| c[:sub] }).to eq([phone.id])
      expect(store.subscriptions.map(&:label)).to eq(["old"])
    end

    it "stops sending after a BadJwtToken until restart, with one warning" do
      client.status = :bad_jwt
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      session(id: "a", question: { id: "q1", kind: "approval" })
      advance(3)
      session(id: "b", question: { id: "q2", kind: "approval" })
      advance(3)
      expect(client.calls.size).to eq(1)
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "push_bad_jwt", hash_including(echo: /web\.push\.contact/)).once
    end

    it "keeps a failure's code on the device and logs no endpoint or text" do
      client.status = :failed
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      session(question: { id: "q1", kind: "approval" })
      advance(3)
      expect(store.find(phone.id).last_error).to eq("500")
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:web, "push_failed", { device: phone.id, code: 500, ms: 3, kind: "approval", error: "500" })
    end
  end

  context "with a device whose key on disk is off the curve, before a good one" do
    let(:posted) { [] }
    # The real Client (its Crypto.encrypt) on a transport that answers 201,
    # the calls recorded as the fake records them.
    let(:client) do
      ok = Struct.new(:code, :body) { def [](_name) = nil }.new("201", "")
      transport = lambda do |uri, _request|
        posted << uri.path
        ok
      end
      real = Samagotchi::Web::Push::Client.new(key: store.vapid_key, contact: "mailto:a@b.c", transport: transport)
      PushNotifierSpecClient.new.tap do |fake|
        fake.define_singleton_method(:deliver) do |sub, payload, ttl:, urgency:|
          calls << { sub: sub.id, payload: payload, ttl: ttl, urgency: urgency }
          real.deliver(sub, payload, ttl: ttl, urgency: urgency)
        end
      end
    end
    let!(:pad) { store.add(WebPushReceiver.new.subscription("https://web.push.apple.com/pad"), origin: origin, label: "iPad") }

    before do
      WebPushReceiver.spoil(store, phone.id)
      notifier.start(PushNotifierSpecHub.new, sender: false)
    end

    it "still pushes to the good one, keeps the bad one's failure and marks the key handled" do
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      session(question: { id: "q1", kind: "approval" })
      expect { advance(3) }.not_to raise_error

      expect(client.calls.map { |c| c[:sub] }).to eq([phone.id, pad.id])
      expect(posted).to eq(["/pad"])
      expect(store.find(phone.id).last_error).to eq("ArgumentError")
      expect(store.find(pad.id).last_ok_at).not_to be_nil
      expect(store.sent_keys.keys).to eq(["s1:q1"])
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "push_failed", hash_including(device: phone.id)).once
    end
  end

  context "with the hour's cap" do
    before { notifier.start(PushNotifierSpecHub.new, sender: false) }

    it "counts update notices against the same hourly cap" do
      31.times do |i|
        update("0.19.#{i}")
        advance(3)
      end

      expect(client.calls.size).to eq(30)
      expect(store.sent_keys.keys).to include("chi:update:0.19.29", "chi:update:0.19.30")
    end

    it "sends 30 shows an hour, holds back the 31st with one warning, and sends again once the hour has moved on" do
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      add_done_device
      31.times do |i|
        session(id: "s#{i}", question: { id: "q", kind: "approval" })
        advance(3)
      end
      session(id: "late", question: { id: "q", kind: "approval" })
      advance(3)
      tags = client.calls.map { |c| c[:payload][:tag] }.uniq
      expect(tags.size).to eq(30)
      expect(client.calls.size).to eq(60) # one event to two devices counts once
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "push_capped", hash_including(cap: 30)).once
      expect(store.sent_keys.keys).to include("s30:q", "late:q")

      advance(3600 - (32 * 3) + 4)
      session(id: "next", question: { id: "q", kind: "approval" })
      advance(3)
      expect(client.calls.last[:payload][:tag]).to eq("next:q")
    end
  end

  context "with a busy push service" do
    before { notifier.start(PushNotifierSpecHub.new, sender: false) }

    it "retries a 429 once after its Retry-After, without holding back another show meanwhile" do
      client.script = [:busy]
      session(id: "a", question: { id: "q1", kind: "approval" })
      advance(1)
      session(id: "b", question: { id: "q2", kind: "approval" })
      advance(2)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(%w[a:q1])
      advance(1)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(%w[a:q1 b:q2])
      advance(0.9)
      expect(client.calls.size).to eq(2)
      advance(0.1)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(%w[a:q1 b:q2 a:q1])
      expect(client.calls.last[:payload][:open]).to eq(%w[a:q1 b:q2])
      expect(store.find(phone.id).last_error).to be_nil
      expect(store.sent_keys.keys).to contain_exactly("a:q1", "b:q2")
    end

    it "gives up after the one retry: push_failed and the error kept" do
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      client.script = %i[error error]
      session(question: { id: "q1", kind: "approval" })
      advance(3)
      advance(10)
      advance(60)
      expect(client.calls.size).to eq(2)
      expect(store.find(phone.id).last_error).to eq("500")
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "push_failed", hash_including(device: phone.id, code: 500)).once
      expect(store.sent_keys).to eq({})
    end

    it "drops the retry of a question answered meanwhile, and retries a failed turn's as is" do
      client.script = %i[busy busy]
      session(id: "a", question: { id: "q1", kind: "approval" })
      session(id: "f", turn: ended("failed", 2))
      advance(3)
      session(id: "a")
      advance(2)
      failed = "f:2026-10-25T09:05:12.345+02:00"
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["a:q1", failed, failed])
    end
  end

  context "when chi web restarts (the seed's catch-up)" do
    let(:wall) { Time.iso8601("2026-10-25T10:00:00+02:00") }
    let(:notifier) do
      described_class.new(store: store, client: client, origin: origin, presence: presence, now: -> { clock[0] }, clock: -> { wall })
    end

    def asked(id, ago, kind: "approval") = summary(id: id, question: { id: "q", kind: kind, created_at: (wall - ago).iso8601(3) })

    it "pushes once an open question asked under an hour ago that no run handled; not one in sent.json, nor an older one" do
      store.mark_sent("seen:q")
      hub = PushNotifierSpecHub.new([asked("new", 600), asked("seen", 60), asked("old", 2 * 3600),
                                     summary(id: "nodate", question: { id: "q", kind: "approval" }),
                                     summary(id: "card", card: { id: "k1", bundle: "check-in" })])
      notifier.start(hub, sender: false)
      advance(3)
      advance(10)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["new:q"])
      expect(client.calls.first[:payload][:badge]).to eq(5)

      again = described_class.new(store: store, client: client, origin: origin, now: -> { clock[0] }, clock: -> { wall })
      again.start(PushNotifierSpecHub.new([asked("new", 600)]), sender: false)
      clock[0] += 10
      again.pump
      expect(client.calls.size).to eq(1)
    ensure
      again&.stop
    end

    it "catches up a step-limit continue and a delegated child's approval with its own hold, not a relayed one" do
      relayed = summary(id: "r", parent_id: "p", question: { id: "q", kind: "approval", relayed_to: "p1234567",
                                                             created_at: wall.iso8601(3) })
      child = summary(id: "c", parent_id: "p", question: { id: "q", kind: "approval", created_at: wall.iso8601(3) })
      notifier.start(PushNotifierSpecHub.new([asked("k", 5, kind: "continue"), child, relayed]), sender: false)
      advance(3)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["k:q"])
      advance(0.5)
      expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["k:q", "c:q"])
    end

    it "keeps a key skipped while a page was in front out of the next run's catch-up" do
      presence.report("desk", true)
      notifier.start(PushNotifierSpecHub.new([asked("a", 60)]), sender: false)
      advance(3)
      expect(client.calls).to eq([])
      expect(store.sent_keys.keys).to eq(["a:q"])
    end
  end

  it "pushes nothing for what the seed snapshot already had open" do
    hub = PushNotifierSpecHub.new([summary(question: { id: "q1", kind: "approval" })])
    notifier.start(hub, sender: false)
    session(question: { id: "q1", kind: "approval" })
    advance(10)
    expect(client.calls).to eq([])
  end

  it "keeps an approval the seed had open in a new show's open list and badge (a chi web restart)" do
    hub = PushNotifierSpecHub.new([summary(id: "a", question: { id: "q1", kind: "approval" })])
    notifier.start(hub, sender: false)
    session(id: "b", question: { id: "q2", kind: "approval" })
    advance(3)
    expect(client.calls.map { |c| c[:payload].values_at(:tag, :open, :badge) }).to eq([["b:q2", %w[a:q1 b:q2], 2]])
  end

  it "seeds from a real hub that has scanned (an open approval there pushes nothing)" do
    state_dir = File.join(root, "sessions")
    hub = Samagotchi::Web::SessionHub.new(state_dir: state_dir, installed_versions: Struct.new(:newest).new(nil))
    open = summary(question: { id: "q1", kind: "approval" })
    allow(Samagotchi::Web::SessionSummary).to receive(:build).and_return(open)
    Samagotchi::Session.new_session(mode: "assist", model_name: "M", working_directory: root).save(state_dir: state_dir)
    hub.scan

    notifier.start(hub, sender: false)
    advance(10)
    expect(client.calls).to eq([])
  end

  it "applies events that came before the seed after it" do
    early = hub_event(type: "session", seq: 9, data: { session: summary(question: { id: "q2", kind: "approval" }) })
    notifier.call(early)
    notifier.seed([summary(question: { id: "q1", kind: "approval" })])
    advance(3)
    expect(client.calls.map { |c| c[:payload][:tag] }).to eq(["s1:q2"])
  end

  it "runs on its own thread, and the sink never waits on a client that blocks" do
    gate = Queue.new
    blocking = Object.new
    delivered = Queue.new
    blocking.define_singleton_method(:deliver) do |_sub, payload, **|
      delivered << payload
      gate.pop(timeout: 30)
      Samagotchi::Web::Push::Client::Result.new(status: :ok, code: 201, ms: 1)
    end
    threaded = described_class.new(store: store, client: blocking, origin: origin, hold: 0.01)
    threaded.start(PushNotifierSpecHub.new)
    threaded.call(hub_event(type: "session", seq: 1, data: { session: summary(question: { id: "q1", kind: "approval" }) }))
    expect(pop!(delivered, "the first push")[:tag]).to eq("s1:q1")

    # The client is stuck in its call: the sink still returns at once.
    caller = Thread.new do
      threaded.call(hub_event(type: "session", seq: 2, data: { session: summary(id: "s2", question: { id: "q2", kind: "approval" }) }))
    end
    join!(caller, "the sink call")
    gate << :go
    expect(pop!(delivered, "the second push")[:tag]).to eq("s2:q2")
    gate << :go
  ensure
    threaded&.stop
  end
end
