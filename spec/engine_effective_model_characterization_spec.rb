# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/memory_bundle/system_bundle"
require_relative "support/fake_provider_server"
require_relative "support/effective_model_configs"

# What the Engine's readers of the effective model answer, per host config,
# pinned on the code as it was before EffectiveModel (characterization: the
# goldens in spec/fixtures/effective_model/ were written by the old
# resolver and must not change with the refactor). Real objects throughout:
# a config.yml, a HostRegistry built from it, real Clients against a fake
# server (llama.cpp's /props and /completion, /v1/chat/completions,
# /v1/messages, /v1/models).
#
# Regenerate only after an intended behaviour change:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/engine_effective_model_characterization_spec.rb
RSpec.describe "Engine effective model (characterization)" do
  include_context "effective model configs"

  def engine_for(model) = Samagotchi::Engine.new(host_registry: registry, model_name: model)

  def session_for(engine, model)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project).tap do |session|
      sessions << session
      engine.store_model!(session)
      engine.session = session
    end
  end

  # A conversation with a thought (what a reasoning_history change to or
  # from all costs the cache).
  def thought_conversation
    [{ role: "user", content: "hi" }, { role: "model", content: "hello", thinking: "they greet me" }]
  end

  def summary_of(value) = value.respond_to?(:summary) ? value.summary : value

  def state_keys = %i[model_name served_model served_model_for served_expected_by context_status llm_context thinking
                      reasoning_history toolkit]

  def stats_keys = %i[served_model served_model_for served_expected_by llm_context thinking reasoning_history price_host
                      profile profile_source]

  # Every reader, in a fixed order (the first profile_resolution may probe).
  def readers(engine)
    resolution = engine.profile_resolution
    stats = engine.stats_snapshot
    {
      effective_model_ref: engine.effective_model_ref,
      effective_model_name: engine.effective_model_name,
      typed_model_name: engine.typed_model_name,
      chat_model: engine.chat_model?,
      profile_resolution: { name: resolution.profile.name, label: resolution.label, retry: resolution.retry? },
      sampling_summary: engine.sampling_summary,
      thinking_summary: engine.thinking_summary,
      thinking_explained: engine.thinking_explained&.summary,
      thinking_explained_own_nil: engine.thinking_explained(own: nil)&.summary,
      thinking_explained_own_low: engine.thinking_explained(own: :low)&.summary,
      thinking_cache_cost: engine.thinking_cache_cost,
      steer_cut_after_explained: engine.steer_cut_after_explained,
      steer_cut_after: engine.steer_cut_after,
      steer_cut_summary: engine.steer_cut_summary,
      reasoning_history_summary: engine.reasoning_history_summary,
      reasoning_history_explained: engine.reasoning_history_explained&.summary,
      reasoning_history_explained_native: engine.reasoning_history_explained(native: true)&.summary,
      reasoning_history_cache_cost: engine.reasoning_history_cache_cost(:drop, :all),
      llm_context_summary: engine.llm_context_summary,
      llm_context_explained: engine.llm_context_explained&.resolved&.to_h,
      served_model_no_probe: engine.served_model(probe: false),
      served_model: engine.served_model,
      served_expected_by_x: engine.served_expected_by("x"),
      served_expected_by_declared: engine.served_expected_by("gpt-x-0613"),
      model_identity: engine.model_identity.to_h,
      guardrail_model_name: engine.guardrail_model_name,
      bare_model_name: engine.bare_model_name(engine.effective_model_name),
      recap_target: engine.send(:session_model_recap_target).to_h,
      backend: engine.backend.class.name,
      session_state_keys: engine.session_state_snapshot.keys,
      session_state: engine.session_state_snapshot.slice(*state_keys),
      stats_keys: stats.keys,
      stats: stats.slice(*stats_keys).merge(window: stats[:context]&.slice(:window_tokens, :window_source))
    }
  end

  def turn_capture(engine, session, settings)
    failed = begin
      engine.run_turn(session, "say ok")
      nil
    rescue StandardError => e
      e.class.name
    end
    turn = settings.last
    {
      failed: failed,
      turn_settings: {
        sampling: turn.sampling, thinking: turn.thinking, reasoning_history: turn.reasoning_history,
        model_name: turn.model_name, window_setting: turn.window_setting&.to_h, llm_context: turn.llm_context&.to_h,
        price: turn.price&.to_h, vision_sendable: turn.vision.sendable?
      },
      system_prompt: EffectiveModelConfigs.sha(normalize(engine.system_prompt))
    }
  end

  def record_turn_settings(engine)
    [].tap do |settings|
      allow(engine.instance_variable_get(:@kernel)).to receive(:turn_settings=).and_wrap_original do |original, value|
        settings << value
        original.call(value)
      end
    end
  end

  def native_reply = "data: #{JSON.generate(content: "ok", stop: false)}\n\ndata: #{JSON.generate(content: "", stop: true)}\n\n"

  def enqueue_reply(row)
    case row
    when "llama", "alias" then server.enqueue("/completion", sse: native_reply)
    when "openai" then server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
    when "anthropic"
      server.enqueue("/v1/messages", sse: FakeProviderServer.fixture("text_stream.hand-written.sse", api: "anthropic"))
    end
  end

  # The request body the turn sent, the system prompt in it as its hash.
  def request_body(row)
    path = { "llama" => "/completion", "alias" => "/completion", "openai" => "/v1/chat/completions",
             "anthropic" => "/v1/messages" }.fetch(row)
    body = server.requests.reverse.find { |request| request.path == path }&.json
    return nil unless body

    body["prompt"] = EffectiveModelConfigs.sha(normalize(body["prompt"])) if body["prompt"].is_a?(String)
    if body["system"]
      body["system"] = EffectiveModelConfigs.sha(normalize(JSON.generate(body["system"])))
    end
    # The tool list by name and hash: its text is the tools' own (pinned elsewhere).
    if body["tools"].is_a?(Array)
      body["tools"] = { "names" => body["tools"].map { |tool| tool["name"] || tool.dig("function", "name") },
                        "digest" => EffectiveModelConfigs.sha(normalize(JSON.generate(body["tools"]))) }
    end
    Array(body["messages"]).each do |message|
      next unless message["role"] == "system"

      message["content"] = EffectiveModelConfigs.sha(normalize(JSON.generate(message["content"])))
    end
    body
  end

  EffectiveModelConfigs::ROWS.each do |row, model|
    it "pins every reader of the effective model on the #{row} config, and one turn's settings and request" do
      engine = engine_for(model)
      session = session_for(engine, model)
      session.messages = thought_conversation
      settings = record_turn_settings(engine)
      values = readers(engine)
      enqueue_reply(row)
      values[:turn] = turn_capture(engine, session, settings)

      expect_golden("#{row}.json", values)
      expect_golden("#{row}_request.json", request_body(row)) unless row == "down"
    end
  end

  # A reader's value, or what it raised.
  def outcome
    yield
  rescue StandardError => e
    { raises: e.class.name, message: e.message }
  end

  describe "when the effective model stops resolving (HostRegistry#resolve raises)" do
    let(:engine) { engine_for("box:qwen-small") }
    let(:session) { session_for(engine, "box:qwen-small") }

    # Built first (initialize resolves unrescued), the profile resolved
    # (profile_resolution's first call resolves unrescued too).
    before do
      session.messages = thought_conversation
      engine.profile_resolution
      allow(registry).to receive(:resolve).and_raise(RuntimeError, "registry broken")
    end

    it "gives each rescued reader its fallback, raises from the others, and the never-resolving readers still answer" do
      error = Samagotchi::LLM::ProviderError.new("boom", host: "box")
      values = {
        rescued: {
          turn_sampling: outcome { engine.turn_sampling },
          turn_thinking: outcome { engine.turn_thinking },
          steer_cut_after_explained: outcome { engine.steer_cut_after_explained },
          steer_cut_after: outcome { engine.steer_cut_after },
          steer_cut_summary: outcome { engine.steer_cut_summary },
          sampling_summary: outcome { engine.sampling_summary },
          thinking_explained: outcome { engine.thinking_explained },
          thinking_summary: outcome { engine.thinking_summary },
          reasoning_history_summary: outcome { engine.reasoning_history_summary },
          reasoning_history_explained: outcome { engine.reasoning_history_explained(native: true) },
          reasoning_history_cache_cost: outcome { engine.reasoning_history_cache_cost(:drop, :all) },
          llm_context_explained: outcome { engine.llm_context_explained },
          llm_context_summary: outcome { engine.llm_context_summary },
          served_expected_by: outcome { engine.served_expected_by("x") },
          served_expected: outcome { engine.served_expected?("x") },
          saved_context_status: outcome { engine.saved_context_status({ used_tokens: 1000, window_tokens: 8000 }) },
          turn_window_setting: outcome { engine.send(:turn_window_setting) },
          turn_price: outcome { engine.send(:turn_price) },
          failure_summary: outcome { engine.failure_summary(error) }
        },
        raising: {
          chat_model: outcome { engine.chat_model? },
          thinking_cache_cost: outcome { engine.thinking_cache_cost },
          model_identity: outcome { engine.model_identity },
          system_prompt: outcome { engine.system_prompt },
          turn_vision: outcome { engine.turn_vision(session) },
          sync_kernel_client: outcome { engine.sync_kernel_client! },
          backend: outcome { engine.backend },
          stats_snapshot: outcome { engine.stats_snapshot },
          served_model_probe: outcome { engine.served_model },
          session_model_recap_target: outcome { engine.send(:session_model_recap_target) }
        },
        never_resolving: {
          effective_model_ref: outcome { engine.effective_model_ref },
          model_ref_for: outcome { engine.model_ref_for("box:qwen-small") },
          bare_model_name: outcome { engine.bare_model_name("box:qwen-small") },
          guardrail_model_name: outcome { engine.guardrail_model_name },
          served_model_no_probe: outcome { engine.served_model(probe: false) },
          store_model: outcome { engine.store_model!(session).model_name },
          profile: outcome { engine.profile.name }
        },
        session_state: outcome { engine.session_state_snapshot.slice(*state_keys) }
      }

      expect_golden("broken.json", values)
      expect(engine.session_state_snapshot.keys).to eq(engine_keys_when_resolving)
    end

    # session_state_snapshot's keys on a resolving model: the same whole hash.
    def engine_keys_when_resolving
      allow(registry).to receive(:resolve).and_call_original
      engine.session_state_snapshot.keys.tap do
        allow(registry).to receive(:resolve).and_raise(RuntimeError, "registry broken")
      end
    end
  end

  # Each read resolves again: a config.yml edit between two reads, with no
  # turn and no /model between them, shows in the second.
  describe "freshness" do
    it "reads config.yml's models: again on every read" do
      engine = engine_for("box:qwen-small")
      session_for(engine, "box:qwen-small")
      before = [engine.steer_cut_after, engine.session_state_snapshot.values_at(:thinking, :llm_context)]
      rewrite_config do |config|
        config["models"]["qwen-small"].merge!("steer_cut_after" => 7, "thinking" => "off", "llm_context_strategy" => "none")
      end
      after = [engine.steer_cut_after, engine.session_state_snapshot.values_at(:thinking, :llm_context)]

      expect(before.first).to eq(45)
      expect(after.first).to eq(7)
      expect(before.last.map { |chip| chip&.values_at(:level, :strategy) }).to eq([["low", nil], [nil, "stale"]])
      expect(after.last.map { |chip| chip&.values_at(:level, :strategy) }).to eq([["off", nil], [nil, "none"]])
    end

    it "reads a chat model's reasoning_history again for /stats" do
      engine = engine_for("oai:gpt-x")
      session_for(engine, "oai:gpt-x")
      before = engine.stats_snapshot[:reasoning_history]
      rewrite_config { |config| config["models"]["gpt-x"]["reasoning_history"] = "drop" }

      expect([before, engine.stats_snapshot[:reasoning_history]])
        .to eq([{ level: "all", source: "hosts.oai", own: nil }, { level: "drop", source: "models: gpt-x", own: nil }])
    end

    it "follows a bare id to the host a model listing found it on, between two reads" do
      engine = engine_for("shared-m")
      session_for(engine, "shared-m")
      read = lambda do
        { chat: engine.chat_model?, price: engine.send(:turn_price)&.to_h, price_host: engine.stats_snapshot[:price_host],
          expected: engine.served_expected_by("shared-m-q8"), ref: engine.effective_model_ref }
      end
      declared = read.call
      allow(registry).to receive(:list_models_for).and_wrap_original do |original, entry|
        next original.call(entry) unless entry.name == "box"

        [Samagotchi::LLM::ModelInfo.new(id: "shared-m", context_window: nil, supports_tools: nil, raw: {})]
      end
      registry.list_all_models
      listed = read.call

      expect(declared).to eq(chat: true, price: { input: 0.5, cache_read: 0.5, cache_write: 0.5, output: 1 },
                             price_host: "oai", expected: "oai", ref: "shared-m")
      expect(listed).to eq(chat: false, price: nil, price_host: "box", expected: nil, ref: "shared-m")
    end
  end

  # The turn's settings come in two places: the thinking, sampling and
  # vision before the hooks (#turn_settings), the model name, window, LLM
  # context and price after them (#generate), with the system prompt.
  it "takes the model name, window and LLM context after a before_turn hook switched the model" do
    engine = engine_for("box:qwen-small")
    session = session_for(engine, "box:qwen-small")
    settings = record_turn_settings(engine)
    engine.register_hook(:before_turn) do |_event|
      rewrite_config do |config|
        config["models"]["gpt-x"].merge!("window_tokens" => 77_000, "llm_context_strategy" => "forget")
      end
      engine.switch_model!("oai:gpt-x")
    end
    server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))

    engine.run_turn(session, "say ok")

    turn = settings.last
    expect(turn.to_h.slice(:sampling, :thinking, :reasoning_history, :model_name))
      .to eq(sampling: { temperature: 0.6, top_k: 20 }, thinking: :low, reasoning_history: :turn, model_name: "gpt-x")
    expect([turn.window_setting.to_h, turn.llm_context.strategy, turn.price&.to_h])
      .to eq([{ tokens: 77_000, source: :model_setting }, [:forget], { input: 1.5, cache_read: 1.5, cache_write: 1.5, output: 6 }])
    request = server.requests.find { |r| r.path == "/v1/chat/completions" }
    expect(request.json["model"]).to eq("gpt-x")
    expect(request.json["messages"].first["content"]).not_to include("<tool_call>")
  end

  # Smoke, not a proof: a reader on another thread while /model switches
  # back and forth doesn't fail, and sees one model or the other, or (on
  # the code this pins) the name of one with the typed name of the other,
  # which reads qwen-small's low: #switch_model! sets the two one by one.
  it "reads the session state on another thread while /model switches" do
    engine = engine_for("box:qwen-small")
    session_for(engine, "box:qwen-small")
    legit = [{ level: "medium", source: "models: fast", own: nil }, { level: "high", source: "models: gemma-x", own: nil }]
    engine.switch_model!("box:qwen-small", typed: "fast")
    stop = false
    seen = []
    reader = Thread.new do
      until stop
        seen << engine.session_state_snapshot[:thinking]
        engine.send(:session_model_recap_target)
      end
    end
    200.times do |i|
      i.even? ? engine.switch_model!("main:gemma-x", typed: "deep") : engine.switch_model!("box:qwen-small", typed: "fast")
    end
    stop = true
    reader.join

    expect(seen).not_to be_empty
    torn = { level: "low", source: "models: qwen-small", own: nil }
    expect(seen.uniq - legit - [torn]).to eq([])
  end

  it "names what an alias became in a failure on its host" do
    engine = engine_for("splash")
    error = Samagotchi::LLM::ProviderError.new("boom", host: "main")

    expect(engine.failure_summary(error)).to eq("#{error.summary} (splash is an alias: gemma-x on host main)")
    expect(engine.failure_summary(Samagotchi::LLM::ProviderError.new("boom", host: "box"))).not_to include("alias")
    session = session_for(engine, "splash")
    expect([session.model_name, session.model_typed]).to eq(%w[main:gemma-x splash])
  end
end
