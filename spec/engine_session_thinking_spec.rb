# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/session"

# The session's own thinking level (Session#thinking) in the Engine: first
# in the level a turn runs at, named in /model's summary, kept by /model,
# and carried by a plugin's fork (Plugin::Host#setup).
RSpec.describe Samagotchi::Engine, "session thinking level" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080, thinking: :high },
                                                 "oai" => { host: "oai.test", port: 8000, api: :openai } })
  end
  let(:engine) { described_class.new(host_registry: registry, model_name: "box:qwen-small", profile: "qwen36") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "box:qwen-small", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  after { ENV.delete("SAMAGOTCHI_THINKING_LEVEL") }

  def turn_level = engine.send(:thinking_level, registry.resolve(engine.effective_model_name))

  it "puts the session's own level over the process default and the host's" do
    engine.session = session
    expect([turn_level, engine.thinking_summary]).to eq([:high, "high (hosts.box)"])

    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    expect([turn_level, engine.thinking_summary]).to eq([:off, "off (SAMAGOTCHI_THINKING_LEVEL)"])

    engine.thinking_override = :low
    expect([turn_level, engine.thinking_summary]).to eq([:low, "low (session)"])
    expect(engine.thinking_explained.summary).to eq(level: "low", source: "session", own: "low")
    expect(session.thinking).to eq(:low)

    engine.thinking_override = nil
    expect(engine.thinking_summary).to eq("off (SAMAGOTCHI_THINKING_LEVEL)")
  end

  it "keeps the session's level across /model" do
    engine.session = session
    engine.thinking_override = :medium
    engine.switch_model!("oai:gpt-x")

    expect(engine.thinking_summary).to eq("medium (session)")
  end

  it "has no level of its own to set without a session" do
    expect(engine.thinking_override).to be_nil
    expect { engine.thinking_override = :low }.to raise_error(ArgumentError, "no session yet")
  end

  it "hands a plugin's fork the session's own setup, thinking included" do
    override = Samagotchi::LLMContextOverride.new(strategy: [:stale])
    session.llm_context = override
    session.thinking = :off
    engine.session = session

    expect(engine.send(:plugin_host).setup.call).to eq(Samagotchi::SessionSetup.new(llm_context: override, thinking: :off))
  end
end
