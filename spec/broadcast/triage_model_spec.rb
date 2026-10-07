# frozen_string_literal: true

require "spec_helper"
require "samagotchi/broadcast/triage_model"
require "samagotchi/host_registry"

RSpec.describe Samagotchi::Broadcast::TriageModel do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { name: "box", host: "box.test", port: 8081 },
      "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY" }
    })
  end

  def resolve(settings)
    described_class.resolve(host_registry: registry, get: ->(key) { settings[key] })
  end

  it "asks broadcast.triage_* first, then the recap's model, then default.model" do
    all = { "broadcast.triage_model" => "small", "broadcast.triage_host_ref" => "fw", "recap.model" => "box:recap",
            "default.model" => "box:big" }

    expect(resolve(all)).to have_attributes(setting: "broadcast.triage_model", problem: nil)
    expect(resolve(all).target.to_h).to eq(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY",
                                           model: "small", label: "small")
    expect(resolve(all.except("broadcast.triage_model", "broadcast.triage_host_ref")).target)
      .to have_attributes(base_url: "http://box.test:8081/v1", model: "recap")
    expect(resolve({ "default.model" => "box:big" })).to have_attributes(setting: "default.model")
    expect(resolve({ "default.model" => "box:big" }).target).to have_attributes(model: "big", label: "box:big")
  end

  it "says what is wrong with triage settings it can't resolve, and doesn't fall back past them" do
    choice = resolve({ "broadcast.triage_model" => "small", "broadcast.triage_host_ref" => "nope", "default.model" => "box:big" })

    expect(choice.to_h).to eq(target: nil, setting: "broadcast.triage_model",
                              problem: "broadcast.triage_host_ref 'nope' is not in hosts:")
    expect(resolve({ "recap.model" => "box:m", "recap.host_ref" => "fw" }).problem)
      .to eq("recap.model 'box:m' names host 'box', not recap.host_ref 'fw'")
  end
end
