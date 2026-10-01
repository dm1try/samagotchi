# frozen_string_literal: true

require "samagotchi/llm/model_result"

RSpec.describe Samagotchi::LLM::ModelResult do
  it "is keyword_init with nil defaults for every field" do
    r = described_class.new(text: "hi")
    expect(r.text).to eq("hi")
    expect(r.conversation).to be_nil
    expect(r.canceled).to be_falsey
    expect(r.cancellation_reason).to be_nil
    expect(r.exhausted).to be_falsey
  end

  it "aliases output to text for renderer compatibility" do
    expect(described_class.new(text: "hello").output).to eq("hello")
  end

  it "exposes a canceled? predicate" do
    expect(described_class.new(text: "x", canceled: true).canceled?).to be(true)
    expect(described_class.new(text: "x").canceled?).to be(false)
  end

  it "exposes an exhausted? predicate (opt-in loop-exit status)" do
    expect(described_class.new(text: "x", exhausted: true).exhausted?).to be(true)
    expect(described_class.new(text: "x").exhausted?).to be(false)
  end

  it "exposes resumable? for renderer compatibility" do
    expect(described_class.new(text: "x", exhausted: true).resumable?).to be(true)
    expect(described_class.new(text: "x").resumable?).to be(false)
  end

  it "stringifies via to_s as text" do
    expect(described_class.new(text: "hi").to_s).to eq("hi")
  end
end

RSpec.describe Samagotchi::LLM::ModelResult, "#empty_answer?" do
  # [text, fields] => empty_answer?
  {
    ["done", {}] => false,
    ["", {}] => true,
    ["  \n", {}] => true,
    ["(placeholder)", { empty_answer: true }] => true,
    ["", { canceled: true }] => false,
    ["", { exhausted: true }] => false,
    ["(placeholder)", { empty_answer: true, canceled: true }] => false,
    ["(placeholder)", { empty_answer: true, exhausted: true }] => false
  }.each do |(text, fields), expected|
    it "is #{expected} for text #{text.inspect} with #{fields}" do
      expect(described_class.new(text: text, **fields).empty_answer?).to be(expected)
    end
  end
end
