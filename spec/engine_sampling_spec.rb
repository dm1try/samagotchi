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

  it "puts the session's own values first, from the next turn's start: the strategy, the apply rule and the budget" do
    models = { "ornith" => { profile: nil, llm_context_strategy: [:stale], llm_context_budget_tokens: 1000 } }
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)

    engine.run_turn(session, "hi")
    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: %i[stale forget], apply: :turn_end, budget_tokens: 0)
    engine.run_turn(session, "again")
    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [])
    engine.run_turn(session, "and again")

    expect(views.map(&:strategy)).to eq([[:stale], %i[stale forget], :none])
    expect(kernel.turn_settings.llm_context.to_h).to include(strategy: :none, source: :session, budget_tokens: 1000)
    expect(engine.llm_context_explained.budget_tokens.source).to eq(:model_setting)
  end

  it "counts a woken worker's saved context status against the session's own budget" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({ "ornith" => { llm_context_budget_tokens: 1000 } })
    session.llm_context = Samagotchi::LLMContextOverride.new(budget_tokens: 2000)
    engine.session = session

    expect(engine.send(:saved_context_status, { used_tokens: 500, window_tokens: 100_000 }))
      .to eq(est_pct: 25.0, bucket: "20plus")
  end

  it "declares forget_outputs in the native prompt only while the session's strategy has forget" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
    engine.session = session
    plain = engine.system_prompt

    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: %i[stale forget])
    expect(engine.system_prompt).to include("forget_outputs")
    session.llm_context = nil
    expect(engine.system_prompt).to eq(plain)
  end

  it "counts the snapshot's context status against a budget the session sets after a turn" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
    engine.session = session
    engine.instance_variable_set(:@last_context_status, { est_pct: 0.5, bucket: nil })
    allow(engine.metrics).to receive(:snapshot).and_wrap_original do |original|
      original.call.merge(context: { used_tokens: 5000, window_tokens: 1_000_000 })
    end

    engine.llm_context_override = Samagotchi::LLMContextOverride.new(budget_tokens: 10_000)

    expect(engine.session_state_snapshot[:context_status]).to eq(est_pct: 50.0, bucket: "40plus")
  end

  it "logs the turn's strategy and its source when it runs a layer or the session set it, and puts it in the snapshot" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
    logged = []
    allow(Samagotchi::Log).to receive(:info).and_call_original
    allow(Samagotchi::Log).to receive(:info).with(:turn, "llm_context", any_args) { |*_args, **fields| logged << fields }

    engine.run_turn(session, "hi")
    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale], budget_tokens: 64_000)
    engine.run_turn(session, "again")

    expect(logged).to eq([{ strategy: "stale", strategy_source: "session", apply: "payoff", apply_source: "config",
                            budget_tokens: 64_000, budget_source: "session" }])
    expect(engine.session_state_snapshot[:llm_context])
      .to include(strategy: "stale", strategy_where: "the session", budget_tokens: 64_000,
                  own: { "strategy" => ["stale"], "budget_tokens" => 64_000 })
  end
end

RSpec.describe Samagotchi::Engine, "#run_turn price" do
  around do |example|
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "work:rr/x") do
      Dir.mktmpdir("chi-state") do |dir|
        @state_dir = dir
        example.run
      end
    end
  end

  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "work" => { host: "gateway.example", port: 443,
                  models: Samagotchi::HostModel.parse_map({ "RR/x" => { "price" => { "input" => 1, "output" => 2 } },
                                                            "rr/y" => { "price" => { "input" => 3, "output" => 4 } },
                                                            "rr/free" => nil }, "work") }
    })
  end
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, host_registry: registry, profile: "qwen36",
                        model_name: "work:rr/x").tap { |e| e.session_state_dir = @state_dir }
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "work:rr/x", working_directory: Dir.pwd) }
  let(:prices) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do |messages, **|
      prices << kernel.turn_settings.price
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
  end

  it "sets the effective model's price from its host's models: on the kernel each turn, nil without one" do
    engine.run_turn(session, "hi")
    engine.switch_model!("work:rr/y")
    engine.run_turn(session, "again")
    engine.switch_model!("work:rr/free")
    engine.run_turn(session, "and again")

    expect(prices.map { |p| p&.to_h }).to eq([{ input: 1, cache_read: 1, cache_write: 1, output: 2 },
                                              { input: 3, cache_read: 3, cache_write: 3, output: 4 }, nil])
  end

  it "follows a before_turn hook's model switch in the same turn" do
    engine.instance_variable_get(:@hooks).register(:before_turn) { |_event| engine.switch_model!("work:rr/y") }

    engine.run_turn(session, "hi")

    expect(prices.map { |p| p&.to_h }).to eq([{ input: 3, cache_read: 3, cache_write: 3, output: 4 }])
  end
end
