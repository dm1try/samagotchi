# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::ModelBackend do
  it "raises NotImplementedError for #complete" do
    expect { described_class.new.complete(messages: []) }.to raise_error(NotImplementedError)
  end
end

RSpec.describe Samagotchi::LLM::Factory do
  it "routes :native to NativeInContextBackend" do
    backend = described_class.factory(provider: :native, model_name: "gemma4")
    expect(backend).to be_a(Samagotchi::LLM::NativeInContextBackend)
  end

  it "raises a descriptive ArgumentError for an unknown provider" do
    expect { described_class.factory(provider: :ruby_llm, model_name: "x") }
      .to raise_error(ArgumentError, /ruby_llm/)
  end
end
