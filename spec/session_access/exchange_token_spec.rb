# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/session_access"
require "samagotchi/session_access/exchange/token"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::SessionAccess::Exchange::Token do
  let(:id) { "3fa2b1c0-0000-4000-8000-000000000000" }
  let(:baseline) { Samagotchi::ReplyWait::Baseline.new(messages: 4, question_id: "q1", last_turn: "2026-11-21T10:00:00Z") }
  let(:start) do
    Samagotchi::SessionAccess::WaitStart.new(cursor: "20261121T100000.txt", baseline: baseline, own_turn: "own",
                                             known_turn: nil, running: true, live: true, settled: true,
                                             last_turn_id: "last")
  end
  let(:delivered) do
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, ack: { "enqueued_id" => "t1", "delivery" => "queue" })
  end

  def raw(fields) = "w1.#{[JSON.generate(fields)].pack("m0").tr("+/", "-_").delete("=")}"

  targets = {
    "message" => ->(s, d) { Samagotchi::ReplyWait::Target.message(s, d, queue: true) },
    "plain message" => ->(s, d) { Samagotchi::ReplyWait::Target.message(s, d, queue: false) },
    "first message (delivered)" => ->(s, d) { Samagotchi::ReplyWait::Target.first_message(s, d) },
    "first message (direct)" => ->(s, _) { Samagotchi::ReplyWait::Target.first_message(s, nil, direct_turn: "first") },
    "first message (none)" => ->(_, _) { Samagotchi::ReplyWait::Target.first_message(nil, nil) },
    "wait only" => ->(s, _) { Samagotchi::ReplyWait::Target.wait_only(s, requested: nil) },
    "wait only (turn)" => ->(s, _) { Samagotchi::ReplyWait::Target.wait_only(s, requested: "last") },
    "answer" => ->(s, _) { Samagotchi::ReplyWait::Target.answer(s) },
    "participant" => ->(s, _) { Samagotchi::ReplyWait::Target.participant(s, turn: "pt") }
  }

  targets.each do |name, build|
    it "round-trips a #{name} target" do
      target = build.call(start, delivered)
      token = described_class.dump(id, target)

      expect(token).to start_with("w1.")
      expect(token).to match(/\Aw1\.[A-Za-z0-9_-]+\z/)
      expect(described_class.load(token)).to eq([id, target])
    end
  end

  it "round-trips a baseline with nulls" do
    target = Samagotchi::ReplyWait::Target.new(baseline: Samagotchi::ReplyWait::Baseline.new(messages: 1))
    expect(described_class.load(described_class.dump(id, target)).last.baseline).to eq(target.baseline)
  end

  refusals = {
    "not a string" => 42,
    "no prefix" => "abc",
    "another version" => "w2.e30",
    "not base64" => "w1.***",
    "not JSON" => "w1.#{["{not json"].pack("m0").tr("+/", "-_").delete("=")}",
    "not an object" => "w1.#{["[1]"].pack("m0").delete("=")}"
  }
  refusals.each do |name, token|
    it "refuses a token that is #{name}" do
      expect { described_class.load(token) }.to raise_error(described_class::Invalid)
    end
  end

  {
    "an unknown key" => { "x" => 1 },
    "no session" => { "s" => nil },
    "a session that isn't an id" => { "s" => "../etc" },
    "a turn that isn't a string" => { "t" => 7 },
    "a cursor that isn't a string" => { "c" => [] },
    "a flag that isn't a boolean" => { "q" => "yes" },
    "a grace that isn't positive" => { "g" => -1 },
    "a baseline with another field" => { "b" => { "other" => 1 } },
    "a baseline of the wrong type" => { "b" => { "messages" => "x" } },
    "a baseline that isn't an object" => { "b" => "x" }
  }.each do |name, change|
    it "refuses #{name}" do
      fields = { "s" => id, "t" => nil, "r" => nil, "q" => false, "e" => false, "c" => nil, "b" => nil, "g" => nil }
      expect { described_class.load(raw(fields.merge(change))) }.to raise_error(described_class::Invalid)
    end
  end

  it "checks a wait body's baseline as a token's (one checker)" do
    expect(described_class.baseline(nil)).to be_nil
    expect(described_class.baseline({ "messages" => 2, "question_id" => nil }))
      .to eq(Samagotchi::ReplyWait::Baseline.new(messages: 2))
    expect { described_class.baseline({ "messages" => 2.5 }) }
      .to raise_error(described_class::Invalid, "baseline is {messages, question_id, last_turn}")
  end
end
