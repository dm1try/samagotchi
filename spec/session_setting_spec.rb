# frozen_string_literal: true

require "samagotchi/session_setting"
require "samagotchi/session"
require "samagotchi/toolkit"
require "samagotchi/llm_context_override"

# The per-session settings' descriptors (the chips' values are pinned in
# spec/web/app_session_settings_characterization_spec.rb and the Engine
# characterization).
RSpec.describe Samagotchi::SessionSetting do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 },
                                                 "oai" => { host: "oai.test", port: 8000, api: :openai } })
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "oai:m", working_directory: Dir.pwd) }

  before { allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({}) }

  it "names the settings in the order every chip list has them, /stats's without the toolkit" do
    expect(described_class::ALL.map(&:key)).to eq(%i[llm_context thinking reasoning_history toolkit])
    expect(described_class::STATS.map(&:key)).to eq(%i[llm_context thinking reasoning_history])
  end

  it "reads and sets the session's own value" do
    described_class::THINKING.set(session, :low)
    described_class::LLM_CONTEXT.set(session, Samagotchi::LLMContextOverride.new(strategy: [:stale]))

    expect(described_class::THINKING.own(session)).to eq(:low)
    expect(described_class::LLM_CONTEXT.own(session).strategy).to eq([:stale])
    expect(described_class::REASONING_HISTORY.own(nil)).to be_nil
  end

  it "says which commands move each chip: /model moves the model's, not the toolkit's" do
    moved = ->(changed) { described_class::ALL.select { |s| s.changed_by?(changed) }.map(&:key) }

    expect(moved.call(%i[model])).to eq(%i[llm_context thinking reasoning_history])
    expect(moved.call(%i[toolkit])).to eq(%i[toolkit])
    expect(moved.call(%i[thinking])).to eq(%i[thinking])
    expect(moved.call([])).to eq([])
  end

  it "takes a worker snapshot's value: llm_context and thinking when truthy, reasoning_history and toolkit when the key is there" do
    chips = ->(snapshot) { described_class::ALL.map { |setting| setting.snapshot_value(snapshot) { :saved } } }
    present = { "llm_context" => 1, "thinking" => 2, "reasoning_history" => 3, "toolkit" => 4 }

    expect(chips.call(present)).to eq([1, 2, 3, 4])
    expect(chips.call(present.transform_values { nil })).to eq([:saved, :saved, nil, nil])
    expect(chips.call({})).to eq(%i[saved saved saved saved])
    expect(chips.call(nil)).to eq(%i[saved saved saved saved])
  end

  it "resolves a saved session's chips from its file; a toolkit by its saved name, nil on full" do
    session.thinking = :medium
    session.toolkit = Samagotchi::Toolkit.new(name: "lean", add: ["delegate"])

    expect(described_class::THINKING.saved_summary(session, registry: registry)).to eq(level: "medium", source: "session", own: "medium")
    expect(described_class::TOOLKIT.saved_summary(session, registry: registry)).to eq(name: "lean", label: "lean +delegate")
    session.toolkit = nil
    expect(described_class::TOOLKIT.saved_summary(session, registry: registry)).to be_nil
    allow(registry).to receive(:resolve).and_raise(RuntimeError, "broken")
    expect(described_class::THINKING.saved_summary(session, registry: registry)).to be_nil
  end
end
