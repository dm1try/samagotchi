# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/session_hub"
require "samagotchi/web/push/client"
require "samagotchi/web/push/notifier"
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
  let(:notifier) { described_class.new(store: store, client: client, origin: origin, now: -> { clock[0] }) }
  let!(:phone) { store.add(WebPushReceiver.new.subscription("https://web.push.apple.com/phone"), origin: origin, label: "iPhone") }

  # Records each delivery; answers +status+ (or what the block says).
  class PushNotifierSpecClient
    Result = Samagotchi::Web::Push::Client::Result

    attr_reader :calls
    attr_accessor :status

    def initialize
      @calls = []
      @status = :ok
    end

    def deliver(sub, payload, ttl:, urgency:)
      @calls << { sub: sub.id, payload: payload, ttl: ttl, urgency: urgency }
      Result.new(status: status, code: { ok: 201, gone: 410, bad_jwt: 403, failed: 500 }[status], ms: 3,
                 error: status == :failed ? "500" : nil)
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
  end

  def summary(id: "s1", question: nil, parent_id: nil, title: "fix the build")
    { id: id, title: title, first_preview: "first", parent_id: parent_id, pending_question: question }.compact
  end

  def hub_event(**) = Samagotchi::Web::SessionHub::Event.new(**)

  def session(**kw) = notifier.call(hub_event(type: "session", seq: 1, data: { session: summary(**kw) }))

  def advance(seconds)
    clock[0] += seconds
    notifier.pump
  end

  def kinds = client.calls.map { |c| c[:payload][:kind] }

  context "when started on a hub" do
    before { notifier.start(PushNotifierSpecHub.new, sender: false) }

    it "pushes a new approval once, after the 3 s hold, with the in-tab words, the session's url and the badge" do
      session(question: { id: "q1", kind: "approval" })
      advance(2.9)
      expect(client.calls).to eq([])
      advance(0.2)
      session(question: { id: "q1", kind: "approval" })
      advance(5)

      expect(client.calls).to eq([{ sub: phone.id, ttl: 12 * 3600, urgency: "high",
                                    payload: { v: 1, kind: "show", tag: "s1:q1", title: "fix the build",
                                               body: "needs approval", url: "/#/s/s1", badge: 1 } }])
      expect(store.find(phone.id).last_ok_at).not_to be_nil
    end

    it "pushes nothing when it is answered within the hold" do
      session(question: { id: "q1", kind: "approval" })
      advance(1)
      session
      advance(10)
      expect(client.calls).to eq([])
    end

    it "sends a close push when a pushed one is answered anywhere" do
      session(question: { id: "q1", kind: "question" })
      advance(3)
      session
      notifier.pump

      expect(kinds).to eq(%w[show close])
      expect(client.calls.last).to include(ttl: 600, urgency: "normal",
                                           payload: { v: 1, kind: "close", tags: ["s1:q1"], badge: 0 })
    end

    it "counts the open waiting ones in the badge" do
      session(id: "a", question: { id: "q1", kind: "approval" })
      session(id: "b", question: { id: "q2", kind: "approval" })
      advance(3)
      expect(client.calls.map { |c| c[:payload][:badge] }).to eq([2, 2])
      notifier.call(hub_event(type: "session", seq: 2, data: { session: summary(id: "a") }))
      notifier.pump
      expect(client.calls.last[:payload]).to include(kind: "close", tags: ["a:q1"], badge: 1)
    end

    it "pushes nothing for one already relayed to its parent, and closes one relayed after it was pushed" do
      session(id: "child", parent_id: "p", question: { id: "q1", kind: "approval", relayed_to: "p1234567" })
      advance(10)
      expect(client.calls).to eq([])

      session(id: "c2", question: { id: "q2", kind: "question" })
      advance(3)
      session(id: "c2", question: { id: "q2", kind: "question", relayed_to: "p1234567" })
      notifier.pump
      expect(kinds).to eq(%w[show close])
    end

    it "holds a delegated child's approval 3.5 s, and a child's hook question too" do
      session(id: "child", parent_id: "p", question: { id: "q1", kind: "approval" })
      session(id: "hooked", parent_id: "p", question: { id: "h1", kind: "hook" })
      advance(3.4)
      expect(client.calls).to eq([])
      advance(0.1)
      expect(client.calls.map { |c| c[:payload][:tag] }).to contain_exactly("child:q1", "hooked:h1")
    end

    it "pushes a hook question as a question, and not a step-limit continue (P1)" do
      session(id: "h", question: { id: "h1", kind: "hook" })
      session(id: "c", question: { id: "c1", kind: "continue" })
      advance(3)
      expect(client.calls.map { |c| c[:payload].values_at(:tag, :body) }).to eq([["h:h1", "needs an answer"]])
    end

    it "closes on session_gone" do
      session(question: { id: "q1", kind: "approval" })
      advance(3)
      notifier.call(hub_event(type: "session_gone", seq: 3, data: { id: "s1" }))
      notifier.pump
      expect(client.calls.last[:payload]).to include(kind: "close", tags: ["s1:q1"])
    end

    it "sends no close for a key it never pushed" do
      session(question: { id: "q1", kind: "approval" })
      session
      advance(10)
      notifier.call(hub_event(type: "session_gone", seq: 3, data: { id: "s1" }))
      notifier.pump
      expect(client.calls).to eq([])
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

  it "pushes nothing for what the seed snapshot already had open" do
    hub = PushNotifierSpecHub.new([summary(question: { id: "q1", kind: "approval" })])
    notifier.start(hub, sender: false)
    session(question: { id: "q1", kind: "approval" })
    advance(10)
    expect(client.calls).to eq([])
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
