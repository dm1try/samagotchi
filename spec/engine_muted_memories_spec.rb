# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"

RSpec.describe Samagotchi::Engine, "muted memories" do
  include_context "thinking off"

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:index) do
    "# Memory Index\n\n- **gh-helper** · system · 2026-09-01 · 120 — GitHub helper\n" \
      "- **cli_usage** · system · 2026-09-01 · 80 — CLI\n"
  end

  def build_engine(**overrides)
    described_class.new(mode: :assist, client: client, kernel: kernel, **overrides)
  end

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_|
      name.to_s.empty? ? index : "BODY-#{name}"
    end
  end

  it "normalizes the --mute list (scope prefix, .md, comma lists) and exposes it" do
    engine = build_engine(profile: "gemma4", muted_memories: ["project/gh-helper, old.md", "gh-helper"])
    expect(engine.muted_memory_names).to eq(%w[gh-helper old])
    expect(engine.session_state_snapshot[:muted_memory_names]).to eq(%w[gh-helper old])
  end

  it "drops the muted memory's index line from the system prompt, keeps the rest" do
    engine = build_engine(profile: "gemma4", muted_memories: ["gh-helper"])
    prompt = engine.system_prompt
    expect(prompt).not_to include("**gh-helper**")
    expect(prompt).to include("- **cli_usage** · system · 2026-09-01 · 80 — CLI")
    expect(prompt).to include("# Memory Index")
  end

  it "leaves the index alone when nothing is muted" do
    expect(build_engine(profile: "gemma4").system_prompt).to include("**gh-helper**")
  end

  it "skips the identity auto-load when identity is muted" do
    expect(build_engine(profile: "gemma4").system_prompt).to include("System identity (auto-loaded")
    engine = build_engine(profile: "gemma4", muted_memories: ["identity"])
    expect(engine.system_prompt).not_to include("System identity (auto-loaded")
  end

  it "removes a muted entry from the preloads, config baseline included, with a warning" do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[user_preferences])
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "preload_muted", hash_including(memory: "user_preferences"))
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "preload_muted", hash_including(memory: "system/cli_usage"))
    engine = build_engine(profile: "gemma4", memories: ["system/cli_usage,notes"],
                                            muted_memories: ["cli_usage", "user_preferences"])
    expect(engine.instance_variable_get(:@requested_memories)).to eq(%w[notes])
    prompt = engine.system_prompt
    expect(prompt).to include("memory name: notes")
    expect(prompt).not_to include("memory name: cli_usage")
    expect(prompt).not_to include("memory name: user_preferences")
  end

  it "reports the effective preload list in the snapshot before any turn ran" do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[user_preferences])
    engine = build_engine(profile: "gemma4", memories: ["system/cli_usage", "cli_usage"], muted_memories: ["gh-helper"])
    snapshot = engine.session_state_snapshot
    expect(snapshot[:preloaded_memory_names]).to eq(%w[user_preferences cli_usage])
    expect(snapshot[:muted_memory_names]).to eq(%w[gh-helper])
    expect(snapshot[:used_memory_names]).to eq([])
  end
end
