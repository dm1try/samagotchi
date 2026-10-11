# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/session"

# reasoning_history in the Engine: the level a turn's settings carry
# (ReasoningHistory.resolve for the turn's model) and /model's summary.
RSpec.describe Samagotchi::Engine, "reasoning history" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 },
                                                 "oai" => { host: "oai.test", port: 8000, api: :openai,
                                                            reasoning_history: :all } })
  end
  let(:model) { "oai:qwen" }
  let(:engine) { described_class.new(host_registry: registry, model_name: model, profile: "qwen36") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: Dir.pwd) }
  let(:models) { {} }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  after { ENV.delete("SAMAGOTCHI_REASONING_HISTORY") }

  def turn_level = engine.send(:turn_settings, session).reasoning_history

  it "puts the host's level in the turn's settings and names it in /model's summary" do
    expect([turn_level, engine.reasoning_history_summary]).to eq([:all, "all (hosts.oai)"])
  end

  context "with a models: entry" do
    let(:models) { { "qwen" => Samagotchi::ModelSettings.new(reasoning_history: :drop) } }

    it "takes the model's over the host's, and the environment's over both" do
      expect([turn_level, engine.reasoning_history_summary]).to eq([:drop, "drop (models: qwen)"])
      ENV["SAMAGOTCHI_REASONING_HISTORY"] = "turn"
      expect([turn_level, engine.reasoning_history_summary]).to eq([:turn, "turn (SAMAGOTCHI_REASONING_HISTORY)"])
    end
  end

  it "is turn by default, which /model doesn't mention" do
    registry.entries["oai"].reasoning_history = nil
    expect([turn_level, engine.reasoning_history_summary]).to eq([:turn, nil])
  end

  context "on a native host" do
    let(:model) { "box:qwen" }

    it "says nothing in /model's summary, even with a level set" do
      registry.entries["box"].reasoning_history = :drop
      expect(engine.reasoning_history_summary).to be_nil
    end
  end
end
