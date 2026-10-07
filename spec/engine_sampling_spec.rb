# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

RSpec.describe Samagotchi::Engine, "#run_turn sampling" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Ornith"
    Dir.mktmpdir("chi-state") do |dir|
      @state_dir = dir
      example.run
    end
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, profile: "qwen36").tap do |e|
      e.session_state_dir = @state_dir
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Ornith", working_directory: Dir.pwd) }
  let(:sampling_set) { [] }
  let(:thinking_set) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:turn_settings=).and_wrap_original do |original, settings|
      sampling_set << settings.sampling
      thinking_set << settings.thinking
      original.call(settings)
    end
    allow(kernel).to receive(:run) do |messages, **|
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
  end

  it "resolves the effective model's sampling each turn and sets it on the kernel" do
    models = { "ornith" => { profile: nil, sampling: { temperature: 0.6 } } }
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)

    engine.run_turn(session, "hi")
    models["ornith"][:sampling] = { temperature: 0.2 }
    engine.run_turn(session, "again")

    expect(sampling_set).to eq([{ temperature: 0.6 }, { temperature: 0.2 }])
  end

  it "sets an empty map when nothing is configured" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})

    engine.run_turn(session, "hi")

    expect(sampling_set).to eq([{}])
  end

  it "resolves the effective model's thinking level each turn and sets it on the kernel" do
    models = { "ornith" => { profile: nil, thinking: :off } }
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)

    engine.run_turn(session, "hi")
    models["ornith"][:thinking] = :high
    engine.run_turn(session, "again")
    models["ornith"].delete(:thinking)
    engine.run_turn(session, "and again")

    expect(thinking_set).to eq(%i[off high default])
  end
end

RSpec.describe Samagotchi::Engine, "#run_turn LLM context strategy" do
  around do |example|
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Ornith") do
      Dir.mktmpdir("chi-state") do |dir|
        @state_dir = dir
        example.run
      end
    end
  end

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, profile: "qwen36").tap { |e| e.session_state_dir = @state_dir }
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Ornith", working_directory: Dir.pwd) }
  let(:views) { [] }

  before do
    Samagotchi::ConfigFile.reset_warnings!
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do |messages, **|
      views << kernel.llm_context_view
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
  end

  it "counts a saved context status against the effective model's llm_context budget, as its turns do" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({ "ornith" => { llm_context_budget_tokens: 1000 } })

    expect(engine.send(:saved_context_status, { used_tokens: 500, window_tokens: 100_000 }))
      .to eq(est_pct: 50.0, bucket: "40plus")
  end

  it "resolves the effective model's strategy each turn: none by default, then stale, then stale with forget" do
    models = {}
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)

    engine.run_turn(session, "hi")
    models["ornith"] = { profile: nil, llm_context_strategy: [:stale] }
    engine.run_turn(session, "again")
    models["ornith"] = { profile: nil, llm_context_strategy: %i[stale forget] }
    engine.run_turn(session, "and again")

    expect(views.map(&:strategy)).to eq([:none, [:stale], %i[stale forget]])
    expect(kernel.turn_settings.llm_context.to_h).to include(layers: %i[stale forget], strategy: %i[stale forget],
                                                             source: :model_setting)
  end
end
