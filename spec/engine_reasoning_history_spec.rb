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

  it "puts the session's own level first, and /model's summary reads it as the session's" do
    engine.session = session
    ENV["SAMAGOTCHI_REASONING_HISTORY"] = "drop"
    engine.reasoning_history_override = :turn
    expect([turn_level, engine.reasoning_history_summary]).to eq([:turn, "turn (session)"])
    expect(engine.reasoning_history_explained.summary).to eq(level: "turn", source: "session", own: "turn")

    engine.reasoning_history_override = nil
    expect(engine.reasoning_history_explained.summary).to eq(level: "drop", source: "SAMAGOTCHI_REASONING_HISTORY", own: nil)
  end

  it "can't set a session's own level without a session" do
    expect { engine.reasoning_history_override = :drop }.to raise_error(ArgumentError, /no session/)
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

    it "explains nothing, even with the session's own level" do
      engine.session = session
      engine.reasoning_history_override = :all
      expect(engine.reasoning_history_explained).to be_nil
    end
  end
end
