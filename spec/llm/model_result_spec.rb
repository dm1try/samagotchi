# frozen_string_literal: true

require "samagotchi/llm/model_result"

RSpec.describe Samagotchi::LLM::ModelResult do
  it "is keyword_init with nil defaults for every field" do
    r = described_class.new(text: "hi")
    expect(r.text).to eq("hi")
    expect(r.tool_calls).to be_nil
    expect(r.provider).to be_nil
    expect(r.usage).to be_nil
    expect(r.metadata).to be_nil
    expect(r.conversation).to be_nil
    expect(r.canceled).to be_falsey
    expect(r.cancellation_reason).to be_nil
  end

  it "aliases output to text for renderer compatibility" do
    expect(described_class.new(text: "hello").output).to eq("hello")
  end

  it "exposes a canceled? predicate" do
    expect(described_class.new(text: "x", canceled: true).canceled?).to be(true)
    expect(described_class.new(text: "x").canceled?).to be(false)
  end

  it "stringifies via to_s as text" do
    expect(described_class.new(text: "hi").to_s).to eq("hi")
  end
end
