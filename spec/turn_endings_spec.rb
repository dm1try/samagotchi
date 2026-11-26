# frozen_string_literal: true

require "samagotchi/turn_endings"
require "samagotchi/image_store"
require "samagotchi/model_profile"

RSpec.describe Samagotchi::TurnEndings do
  describe ".failure_line" do
    it "says chi failed, with the message's first line, its class and where the details are" do
      error = RuntimeError.new("boom\nat line 2")

      expect(described_class.failure_line(error)).to eq("chi error: boom (RuntimeError); details in samagotchi.log")
    end

    it "reads a message holding raw bytes as UTF-8 (the bytes that failed may be in it)" do
      line = described_class.failure_line(RuntimeError.new("bad \xFF naïve".b))

      expect(line).to be_valid_encoding
      expect(line).to eq("chi error: bad ? naïve (RuntimeError); details in samagotchi.log")
    end

    it "keeps a provider error's summary and a UserError's message" do
      provider = Samagotchi::LLM::ServerError.new("HTTP 500", host: "fw", status: 500)

      expect(described_class.failure_line(provider)).to eq(provider.summary)
      expect(described_class.failure_line(Samagotchi::ImageStore::Error.new("x.png is not an image"))).to eq("x.png is not an image")
      expect(described_class.failure_line(Samagotchi::ModelProfile::UnknownHost.new("no host fw"))).to eq("no host fw")
    end
  end

  describe "#failed_event" do
    let(:endings) { described_class.new(failure_summary: ->(error) { "summary of #{error.message}" }) }

    it "gives chi's own error its kind and line; a provider error's and a UserError's stay as they were" do
      chi = endings.failed_event(IOError.new("disk"), 0.5)
      provider = endings.failed_event(Samagotchi::LLM::ServerError.new("HTTP 500", host: "fw", status: 500), 0.5)
      user = endings.failed_event(Samagotchi::ImageStore::Error.new("x.png is not an image"), 0.5)

      expect(chi).to eq(type: :turn_failed, error_class: "IOError", message: "disk", duration_ms: 500,
                        error_kind: :chi_error, summary: "chi error: disk (IOError); details in samagotchi.log")
      expect(provider).to include(error_kind: :server, retryable: false, host: "fw", summary: "summary of HTTP 500")
      expect(user).to eq(type: :turn_failed, error_class: "Samagotchi::ImageStore::Error", message: "x.png is not an image",
                         duration_ms: 500)
      expect(endings.stop_facts(chi)).to eq(error_kind: "chi_error", retryable: nil, kept_steps: nil)
    end
  end
end
