# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/memory_bundle/system_bundle"
require_relative "support/fake_provider_server"
require_relative "support/effective_model_configs"

# The Engine's readers of the session's settings on its effective model,
# with the session's own thinking, reasoning_history and llm_context set
# (spec/engine_effective_model_characterization_spec.rb pins them with
# none), without a session, and as the session and the model change between
# two reads. Pinned before the readers move to SessionModelSettings: the
# values must not change with the move.
RSpec.describe "Engine session model settings (characterization)" do
  include_context "effective model configs"

  def engine_for(model) = Samagotchi::Engine.new(host_registry: registry, model_name: model)

  def session_for(engine, model)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project).tap do |session|
      sessions << session
      engine.store_model!(session)
      engine.session = session
    end
  end

  # The session's own values on every setting, and a reply with a thought.
  def own_values!(engine, session)
    session.messages = [{ role: "user", content: "hi" }, { role: "model", content: "hello", thinking: "they greet me" }]
    engine.thinking_override = :medium
    engine.reasoning_history_override = :drop
    engine.llm_context_override = Samagotchi::LLMContextOverride.new(strategy: [:forget], budget_tokens: 64_000)
  end

  def readers(engine)
    turn = engine.send(:turn_settings, engine.session)
    {
      own: [engine.thinking_override, engine.reasoning_history_override, engine.llm_context_override&.to_h],
      thinking: [engine.thinking_summary, engine.thinking_explained&.summary, engine.turn_thinking],
      reasoning_history: [engine.reasoning_history_summary, engine.reasoning_history_explained&.summary,
                          engine.reasoning_history_explained(native: true)&.summary,
                          engine.reasoning_history_cache_cost(:drop, :all)],
      llm_context: [engine.llm_context_summary&.slice(:strategy, :strategy_source, :budget_tokens, :budget_source, :own),
                    engine.llm_context_explained&.resolved&.to_h&.slice(:strategy, :source, :budget_tokens)],
      saved_context_status: [engine.saved_context_status({ used_tokens: 1000, window_tokens: 8000 }),
                             engine.saved_context_status({ used_tokens: 32_000, window_tokens: 128_000 },
                                                         model: engine.send(:effective_model))],
      turn: [turn.thinking, turn.reasoning_history, turn.sampling],
      state: engine.session_state_snapshot.slice(:thinking, :reasoning_history),
      stats: engine.stats_snapshot.slice(:thinking, :reasoning_history)
    }
  end

  let(:own_thinking) { { level: "medium", source: "session", own: "medium" } }
  let(:own_drop) { { level: "drop", source: "session", own: "drop" } }
  let(:own_llm_context) do
    [{ strategy: "forget", strategy_source: "session", budget_tokens: 64_000, budget_source: "session",
       own: { "strategy" => ["forget"], "budget_tokens" => 64_000 } },
     { strategy: [:forget], source: :session, budget_tokens: 64_000 }]
  end

  it "reads the session's own values first on a chat model" do
    engine = engine_for("oai:gpt-x")
    own_values!(engine, session_for(engine, "oai:gpt-x"))

    expect(readers(engine)).to eq(
      own: [:medium, :drop, { strategy: [:forget], apply: nil, budget_tokens: 64_000 }],
      thinking: ["medium (session)", own_thinking, :medium],
      reasoning_history: ["drop (session)", own_drop, own_drop, :history],
      llm_context: own_llm_context,
      saved_context_status: [{ est_pct: 12.5, bucket: "under20" }, { est_pct: 50.0, bucket: "40plus" }],
      turn: [:medium, :drop, { temperature: 0.3 }],
      state: { thinking: own_thinking, reasoning_history: own_drop },
      stats: { thinking: own_thinking, reasoning_history: own_drop }
    )
  end

  it "reads them on a native model, where reasoning_history shows only when asked for native: true" do
    engine = engine_for("box:qwen-small")
    own_values!(engine, session_for(engine, "box:qwen-small"))

    expect(readers(engine)).to eq(
      own: [:medium, :drop, { strategy: [:forget], apply: nil, budget_tokens: 64_000 }],
      thinking: ["medium (session)", own_thinking, :medium],
      reasoning_history: [nil, nil, own_drop, nil],
      llm_context: own_llm_context,
      saved_context_status: [{ est_pct: 12.5, bucket: "under20" }, { est_pct: 50.0, bucket: "40plus" }],
      turn: [:medium, :drop, { temperature: 0.6, top_k: 20 }],
      state: { thinking: own_thinking, reasoning_history: nil },
      stats: { thinking: own_thinking, reasoning_history: nil }
    )
  end

  it "reads the model's values without a session, and refuses to set an own value" do
    engine = engine_for("box:qwen-small")

    expect([engine.thinking_override, engine.reasoning_history_override, engine.llm_context_override]).to eq([nil, nil, nil])
    expect([engine.thinking_summary, engine.turn_thinking, engine.saved_context_status(nil)])
      .to eq(["low (models: qwen-small)", :low, nil])
    expect(engine.llm_context_summary.slice(:strategy, :strategy_source)).to eq(strategy: "stale", strategy_source: "model_setting")
    expect { engine.thinking_override = :low }.to raise_error(ArgumentError, "no session yet")
    expect { engine.reasoning_history_override = :all }.to raise_error(ArgumentError, "no session yet")
    expect { engine.llm_context_override = Samagotchi::LLMContextOverride.new }.to raise_error(ArgumentError, "no session yet")
  end

  it "follows the session and the model between two reads (nothing kept)" do
    engine = engine_for("box:qwen-small")
    first = session_for(engine, "box:qwen-small")
    own_values!(engine, first)
    session_for(engine, "box:qwen-small")

    expect([engine.thinking_override, engine.thinking_summary, engine.reasoning_history_cache_cost(:drop, :all)])
      .to eq([nil, "low (models: qwen-small)", nil])

    engine.session = first
    engine.switch_model!("oai:gpt-x")

    expect([engine.chat_model?, engine.sampling_summary, engine.thinking_summary, engine.reasoning_history_summary,
            engine.steer_cut_after_explained, engine.served_expected_by("gpt-x-0613"), engine.served_expected?("x")])
      .to eq([true, "temperature=0.3 (models: gpt-x)", "medium (session)", "drop (session)", [20, nil], "oai", false])
  end
end
