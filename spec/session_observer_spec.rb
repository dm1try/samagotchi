# frozen_string_literal: true

require "samagotchi/session_observer"

RSpec.describe Samagotchi::SessionObserver do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:observer) { described_class.new }

  def collecting
    Array.new.tap do |arr|
      arr << ->(event) { arr << event }
    end
  end

  describe "#subscribe / #unsubscribe handles" do
    it "returns a handle responding to #unsubscribe and #unsubscribed?" do
      handle = observer.subscribe(observer: ->(_e) {})
      expect(handle).to be_a(described_class::SubscribedObserver)
      expect(handle.unsubscribed?).to be_falsey
      expect(handle.unsubscribed?).to be_falsey
    end

    it "unsubscribe returns true the first time and false afterwards (idempotent)" do
      handle = observer.subscribe(observer: ->(_e) {})
      expect(handle.unsubscribe).to be_truthy
      expect(handle.unsubscribe).to be_falsey
      expect(handle.unsubscribed?).to be_truthy
    end

    it "unsubscribe(nil) does not raise and returns false" do
      expect(observer.unsubscribe(handle: nil)).to be(false)
    end

    it "unsubscribe of an unknown handle does not raise and returns false" do
      other = observer.subscribe(observer: ->(_e) {})
      expect(observer.unsubscribe(handle: other)).to be(true)
      expect(observer.unsubscribe(handle: other)).to be(false)
    end
  end

  describe "#notify" do
    it "delivers the event (with event_seq) to a subscriber" do
      events = []
      handle = observer.subscribe(observer: ->(event) { events << event })
      observer.notify(type: :generation_started)
      expect(events.length).to eq(1)
      expect(events.first[:type]).to eq(:generation_started)
      expect(events.first[:event_seq]).to eq(1)
      expect(handle.unsubscribed?).to be_falsey
    end

    it "never mutates the original event hash" do
      original = { type: :turn_started }
      received = nil
      observer.subscribe(observer: ->(event) { received = event })
      observer.notify(original)
      expect(received).not_to eq(original)
      expect(received[:event_seq]).to be(1)
      expect(original).to eq({ type: :turn_started })
    end

    it "assigns strictly increasing event_seq, consecutive within a notify sequence" do
      seqs = []
      observer.subscribe(observer: ->(event) { seqs << event[:event_seq] })
      observer.notify(type: :a)
      observer.notify(type: :b)
      observer.notify(type: :c)
      expect(seqs).to eq([1, 2, 3])
    end

    it "event_count increments once per emit" do
      observer.subscribe(observer: ->(_e) {})
      observer.notify(type: :a)
      observer.notify(type: :b)
      expect(observer.event_count).to eq(2)
    end

    it "fans out identical events to multiple subscribers" do
      first = []
      second = []
      observer.subscribe(observer: ->(event) { first << event })
      observer.subscribe(observer: ->(event) { second << event })
      observer.notify(type: :turn_started, prompt: "hi")
      expect(first).to eq(second)
      expect(first.length).to eq(1)
      expect(first.first[:prompt]).to eq("hi")
    end

    it "subscribed before emits see events; events before subscribe are not replayed" do
      late = []
      observer.notify(type: :past_event)
      handle = observer.subscribe(observer: ->(event) { late << event })
      observer.notify(type: :future_event)
      expect(late.map { |e| e[:type] }).to eq([:future_event])
      expect(late.first[:event_seq]).to eq(2)
    end

    it "unsubscribing stops delivery for that subscriber without affecting others" do
      keep = []
      drop = []
      handle = observer.subscribe(observer: ->(event) { drop << event })
      observer.subscribe(observer: ->(event) { keep << event })
      observer.notify(type: :before)
      handle.unsubscribe
      observer.notify(type: :after)
      expect(keep.map { |e| e[:type] }).to eq([:before, :after])
      expect(drop.map { |e| e[:type] }).to eq([:before])
    end

    it "isolates a raising subscriber so others still receive and it does not raise" do
      other = []
      observer.subscribe(observer: ->(event) { other << event })
      observer.subscribe(observer: ->(_e) { raise "boom" })
      expect { observer.notify(type: :boom) }.not_to raise_error
      expect(other.map { |e| e[:type] }).to eq([:boom])
    end

    it "still delivers to other subscribers when one unregisters mid-sequence" do
      first = []
      second = []
      handle = observer.subscribe(observer: ->(event) { first << event })
      observer.subscribe(observer: ->(event) { second << event })
      handle.unsubscribe
      observer.notify(type: :after_unsub)
      expect(first).to eq([])
      expect(second.map { |e| e[:type] }).to eq([:after_unsub])
    end
  end
end
