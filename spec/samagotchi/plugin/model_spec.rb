# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/plugin/context"

# ctx.model / ctx.model_key: the model the session runs on now (the
# resolved ref, live right after /model) and its memory overlay key;
# ctx.model_names: the names chi's own per-model config looks it up under.
RSpec.describe "ctx.model and ctx.model_key" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "box:Gemma-Small", profile: "gemma4") }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host)) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  it "is the session's model ref and its overlay key, before and after a switch" do
    expect([ctx.model, ctx.model_key]).to eq(%w[box:Gemma-Small gemma-small])

    engine.switch_model!("oai:Qwen3.8-27B")
    expect([ctx.model, ctx.model_key]).to eq(%w[oai:Qwen3.8-27B qwen3-8-27b])
  end

  it "is nil on a host without them" do
    bare = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: Samagotchi::Plugin::Host.new)
    expect([bare.model, bare.model_key, bare.model_names]).to eq([nil, nil, []])
  end

  describe "ctx.model_names" do
    before { allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "tiny" => "box:Gemma-Small" }) }

    let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "tiny", profile: "gemma4") }

    it "names the model as typed (an alias), its target, without the host and the bare id, frozen; again after /model" do
      expect(ctx.model_names).to eq(%w[tiny box:Gemma-Small Gemma-Small])
      expect(ctx.model_names).to be_frozen

      engine.switch_model!("oai:Qwen3.8-27B")
      expect(ctx.model_names).to eq(%w[oai:Qwen3.8-27B Qwen3.8-27B])
    end

    it "is [] when the model doesn't resolve" do
      allow(engine).to receive(:effective_model).and_raise(ArgumentError, "unknown host")
      expect(ctx.model_names).to eq([])
    end
  end
end
