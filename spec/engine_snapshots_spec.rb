# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine_snapshots"

RSpec.describe Samagotchi::EngineSnapshots do
  # Every lookup answers nil unless the example gives its own.
  def snapshots(**lookups)
    keys = described_class.instance_method(:initialize).parameters.map(&:last)
    described_class.new(**keys.to_h { |key| [key, ->(*, **) {}] }, **lookups)
  end

  describe "#served_model_for" do
    it "a report for the asked name, else nothing without a model" do
      subject = snapshots(effective_model_name: -> { "qwen" }, bare_model_name: ->(ref) { ref })

      expect(subject.served_model_for({ served_model: "ornith", served_model_for: "qwen" })).to eq(%w[ornith qwen])
      expect(subject.served_model_for({ served_model: "ornith", served_model_for: "other" })).to eq([nil, nil])
    end

    it "is [nil, nil] when the name can't be read, logged" do
      allow(Samagotchi::Log).to receive(:warn)
      subject = snapshots(effective_model_name: -> { raise ArgumentError, "no host" })

      expect(subject.served_model_for({})).to eq([nil, nil])
      expect(Samagotchi::Log).to have_received(:warn).with(:model, "served_model_unreadable", hash_including(error: "ArgumentError"))
    end
  end
end
