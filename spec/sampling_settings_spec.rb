# frozen_string_literal: true

require "samagotchi/sampling_settings"
require "samagotchi/host_registry"

RSpec.describe Samagotchi::SamplingSettings do
  def target(sampling: nil, model: "work:Qwen3.6-35B", bare: "Qwen3.6-35B")
    entry = Samagotchi::HostRegistry::HostEntry.new(name: "work", host: "h", port: 1, api: :openai, sampling: sampling)
    Samagotchi::HostRegistry::ModelTarget.new(model: model, entry: entry, bare_model: bare, client: nil)
  end

  def names(target) = [target.model, target.bare_model]

  it "is empty and frozen when nothing is configured" do
    result = described_class.for(target, names: names(target), models: {})

    expect(result).to eq({})
    expect(result).to be_frozen
    expect(described_class.summary(target, names: names(target), models: {})).to be_nil
  end

  it "takes the host's map alone" do
    expect(described_class.for(t = target(sampling: { temperature: 0.6, presence_penalty: 1.5 }), names: names(t), models: {}))
      .to eq(temperature: 0.6, presence_penalty: 1.5)
  end

  it "takes the model's map alone, found by the bare name" do
    models = { "qwen3.6-35b" => { profile: nil, sampling: { temperature: 0.7 } } }

    expect(described_class.for(target, names: names(target), models: models)).to eq(temperature: 0.7)
  end

  it "merges the two, the model's keys winning per key" do
    models = { "qwen3.6-35b" => { profile: nil, sampling: { temperature: 0.7, top_p: 0.95 } } }
    t = target(sampling: { temperature: 0.6, presence_penalty: 1.5 })

    expect(described_class.for(t, names: names(t), models: models)).to eq(temperature: 0.7, presence_penalty: 1.5, top_p: 0.95)
    expect(described_class.summary(t, names: names(t), models: models))
      .to eq("temperature=0.7 presence_penalty=1.5 top_p=0.95 (hosts.work, models: qwen3.6-35b)")
  end

  it "finds a models: entry under an alias among the lookup names, first name first" do
    models = { "fast" => { profile: nil, sampling: { temperature: 0.3 } },
               "qwen3.6-35b" => { profile: nil, sampling: { temperature: 0.9 } } }

    expect(described_class.for(target, names: ["fast", "Qwen3.6-35B"], models: models)).to eq(temperature: 0.3)
  end

  it "shows a null value as not sent" do
    expect(described_class.summary(t = target(sampling: { temperature: nil }), names: names(t), models: {}))
      .to eq("temperature=(not sent) (hosts.work)")
  end
end
