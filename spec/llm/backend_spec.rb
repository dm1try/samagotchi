# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::ModelBackend do
  it "raises NotImplementedError for #complete" do
    expect { described_class.new.complete(messages: []) }.to raise_error(NotImplementedError)
  end
end
