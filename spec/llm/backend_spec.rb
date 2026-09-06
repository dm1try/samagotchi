# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::ModelBackend do
  it "raises NotImplementedError for #complete" do
    expect { described_class.new.complete(messages: []) }.to raise_error(NotImplementedError)
  end
end

RSpec.describe Samagotchi::LLM::Factory do
  it "returns nil for :native (engine drives KernelLoop directly)" do
    backend = described_class.factory(provider: :native, model_name: "gemma4")
    expect(backend).to be_nil
  end

  it "routes :ruby_llm to RubyLLMBackend" do
    backend = described_class.factory(provider: :ruby_llm, model_name: "x")
    expect(backend).to be_a(Samagotchi::LLM::RubyLLMBackend)
  end

  it "raises a descriptive ArgumentError for an unknown provider" do
    expect { described_class.factory(provider: :watson, model_name: "x") }
      .to raise_error(ArgumentError, /native.*ruby_llm|ruby_llm.*native/)
  end
end
