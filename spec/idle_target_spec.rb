# frozen_string_literal: true

require "spec_helper"
require "samagotchi/idle_target"
require "samagotchi/host_registry"

# The side model's settings as a target (RecapSetup's cases are in
# engine_recap_host_spec and model_ref_spec; a broadcast's triage uses it too).
RSpec.describe Samagotchi::IdleTarget do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { name: "box", host: "box.test", port: 8081 },
      "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY" }
    })
  end

  def resolve(model: nil, host_ref: nil, base_url: nil)
    described_class.resolve(model: model, host_ref: host_ref, base_url: base_url, host_registry: registry)
  end

  it "is nil when nothing is set, blanks included: the caller picks its default" do
    expect(resolve).to be_nil
    expect(resolve(model: " ", host_ref: "", base_url: nil)).to be_nil
  end

  it "pins a host by host_ref, by the model's own host prefix or by base_url" do
    expect(resolve(model: "small", host_ref: "fw").to_h)
      .to eq(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY", model: "small", label: "small")
    expect(resolve(model: "box:small").to_h)
      .to eq(base_url: "http://box.test:8081/v1", api_key_env: nil, model: "small", label: "box:small")
    expect(resolve(model: "m", base_url: "http://other.test/v1 ").to_h)
      .to eq(base_url: "http://other.test/v1", api_key_env: nil, model: "m", label: "m")
  end

  it "says which setting is wrong when it can't be resolved" do
    expect { resolve(model: "m", host_ref: "nope") }
      .to raise_error(described_class::Unresolved) { |e| expect([e.reason, e.host_ref]).to eq([:host_ref_unknown, "nope"]) }
    expect { resolve(model: "box:m", host_ref: "fw") }
      .to raise_error(described_class::Unresolved) { |e| expect([e.reason, e.named]).to eq([:model_host_mismatch, "box"]) }
    expect { resolve(host_ref: "fw") }
      .to raise_error(described_class::Unresolved) { |e| expect(e.reason).to eq(:incomplete) }
  end

  it "tells a fixed host from a model alone, which goes where a bare --model goes" do
    expect(described_class.host_named?(model: "m", host_ref: nil, base_url: nil, host_registry: registry)).to be(false)
    expect(described_class.host_named?(model: "box:m", host_ref: nil, base_url: nil, host_registry: registry)).to be(true)
    expect(described_class.host_named?(model: "m", host_ref: "fw", base_url: nil, host_registry: registry)).to be(true)
    expect(resolve(model: "m")).to have_attributes(model: "m", label: "m")
  end
end
