# frozen_string_literal: true

require "json"
require "samagotchi/effective_model"
require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_provider_server"
require_relative "support/effective_model_configs"

RSpec.describe Samagotchi::EffectiveModel do
  include_context "effective model configs"

  def choice(model, typed = model) = Samagotchi::ModelChoice.new(name: model, typed: typed)

  def thought_conversation = [{ role: "user", content: "hi" }, { role: "model", content: "hello", thinking: "they greet me" }]

  # The settings as the Engine's readers give them, and as an EffectiveModel
  # of the same choice does.
  def engine_view(engine)
    {
      chat: engine.chat_model?, sampling_summary: engine.sampling_summary,
      thinking_explained: engine.thinking_explained(own: :low)&.summary, thinking_cache_cost: engine.thinking_cache_cost,
      reasoning_history_summary: engine.reasoning_history_summary,
      reasoning_history_explained: engine.reasoning_history_explained(native: true, own: :drop)&.summary,
      reasoning_history_cache_cost: engine.reasoning_history_cache_cost(:drop, :all),
      steer_cut_after_explained: engine.steer_cut_after_explained, llm_context: engine.llm_context_explained&.resolved&.to_h,
      served_expected_by: engine.served_expected_by("gpt-x-0613"), served: engine.served_model,
      prompt_served: engine.model_identity.served, profile: engine.profile_resolution.label,
      window_setting: engine.send(:turn_window_setting)&.to_h, price: engine.send(:turn_price)&.to_h,
      turn_sampling: engine.turn_sampling, turn_thinking: engine.turn_thinking,
      vision: engine.turn_vision(engine.session).capability
    }
  end

  def model_view(model, engine)
    {
      chat: model.chat?, sampling_summary: model.sampling_summary,
      thinking_explained: model.thinking_explained(own: :low)&.summary,
      thinking_cache_cost: model.thinking_cache_cost { engine.profile },
      reasoning_history_summary: model.reasoning_history_summary(own: nil),
      reasoning_history_explained: model.reasoning_history_explained(native: true, own: :drop)&.summary,
      reasoning_history_cache_cost: model.reasoning_history_cache_cost(:drop, :all, conversation: thought_conversation),
      steer_cut_after_explained: model.steer_cut_after_explained, llm_context: model.llm_context_explained({})&.resolved&.to_h,
      served_expected_by: model.served_expected_by("gpt-x-0613"), served: model.served_from_props(model.registry.bare_name(model.name)),
      prompt_served: model.prompt_served, profile: model.profile_resolution.label,
      window_setting: model.window_setting&.to_h, price: model.price&.to_h,
      turn_sampling: model.sampling, turn_thinking: model.thinking(own: nil),
      vision: model.vision_support(engine.profile)
    }
  end

  EffectiveModelConfigs::ROWS.each do |row, model|
    it "reads each setting as the Engine's readers do on the #{row} config" do
      engine = Samagotchi::Engine.new(host_registry: registry, model_name: model)
      engine.session = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project)
      engine.session.messages = thought_conversation
      effective = described_class.of(registry, choice(engine.effective_model_name, engine.typed_model_name))

      expect(model_view(effective, engine)).to eq(engine_view(engine))
      expect([effective.ref, effective.bare, effective.host_name])
        .to eq([engine.effective_model_ref, engine.bare_model_name(model), engine.stats_snapshot[:price_host]])
      expect(effective.context_window.to_h).to eq(engine.stats_snapshot[:context].slice(:window_tokens, :window_source)
                                                    .then { |w| { tokens: w[:window_tokens], source: w[:window_source]&.to_sym } })
    end
  end

  it "looks a models: entry up under the name typed first, then what it became" do
    effective = described_class.of(registry, choice("main:gemma-x", "splash"))

    expect(effective.names).to eq(%w[splash main:gemma-x gemma-x])
    expect(effective.thinking_explained(own: nil).summary).to eq(level: "off", source: "models: splash", own: nil)
    expect(effective.thinking(own: :high)).to eq(:high)
  end

  it "builds a saved session's from its model and the name it was typed as, the default for a blank one" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-x", working_directory: project)
    session.model_typed = "splash"
    blank = Samagotchi::Session.new_session(mode: "assist", model_name: "", working_directory: project)

    expect(described_class.of_session(session, registry: registry))
      .to have_attributes(name: "main:gemma-x", typed: "splash", host_name: "main", bare: "gemma-x")
    expect(described_class.of_session(blank, registry: registry)).to have_attributes(name: "box:qwen-small", typed: "box:qwen-small")
  end

  it "raises as HostRegistry#resolve does when it can't be built" do
    allow(registry).to receive(:resolve).and_raise(RuntimeError, "registry broken")

    expect { described_class.of(registry, choice("box:qwen-small")) }.to raise_error(RuntimeError, "registry broken")
  end

  # A setting that fails once the model resolved gives the fallback the
  # Engine has always given for it.
  it "gives each setting's fallback when its own resolution fails" do
    effective = described_class.of(registry, choice("oai:gpt-x"))
    [Samagotchi::SamplingSettings, Samagotchi::Thinking, Samagotchi::ReasoningHistory, Samagotchi::SteerCutAfter,
     Samagotchi::LLMContextStrategy, Samagotchi::ServedModel].each do |mod|
      %i[for summary resolve explain cache_cost expected_by from_props].each do |name|
        allow(mod).to receive(name).and_raise(RuntimeError, "setting broken") if mod.respond_to?(name)
      end
    end
    allow(Samagotchi::ContextWindow).to receive(:setting).and_raise(RuntimeError, "setting broken")
    allow(registry).to receive(:adapter_for).and_raise(RuntimeError, "adapter broken")
    allow(effective.entry).to receive(:models).and_raise(RuntimeError, "models broken")

    expect([effective.sampling, effective.sampling_summary, effective.thinking(own: nil), effective.thinking_explained(own: nil),
            effective.reasoning_history(own: nil), effective.reasoning_history_explained(own: nil),
            effective.reasoning_history_summary(own: nil), effective.reasoning_history_cache_cost(:drop, :all, conversation: []),
            effective.steer_cut_after_explained, effective.llm_context_explained({}), effective.llm_context_layers({}),
            effective.window_setting, effective.context_window, effective.price, effective.served_from_props("gpt-x"),
            effective.served_expected_by("x"), effective.prompt_served, effective.vision_adapter])
      .to eq([Samagotchi::SamplingSettings::EMPTY, nil, Samagotchi::Thinking::DEFAULT, nil, Samagotchi::ReasoningHistory::DEFAULT,
              nil, nil, nil, [Samagotchi::SteerCut.cut_after, "steer.cut_after"], nil, [], nil, nil, nil, [nil, nil], nil, nil, nil])
  end

  it "names only the model, its typed name and host when inspected (never the registry or a client)" do
    effective = described_class.of(registry, choice("main:gemma-x", "splash"))

    expect(effective.inspect).to eq('#<Samagotchi::EffectiveModel "main:gemma-x" typed="splash" host="main">')
    expect(effective).to be_frozen
  end

  # The torn read P0's thread smoke tolerated: #switch_model! now swaps the
  # name and the typed name as one ModelChoice.
  it "never pairs one model's name with the other's typed name for a reader on another thread" do
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: "box:qwen-small")
    engine.session = Samagotchi::Session.new_session(mode: "assist", model_name: "box:qwen-small", working_directory: project)
    legit = [{ level: "medium", source: "models: fast", own: nil }, { level: "high", source: "models: gemma-x", own: nil }]
    engine.switch_model!("box:qwen-small", typed: "fast")
    stop = false
    seen = []
    reader = Thread.new { seen << engine.session_state_snapshot[:thinking] until stop }
    300.times do |i|
      i.even? ? engine.switch_model!("main:gemma-x", typed: "deep") : engine.switch_model!("box:qwen-small", typed: "fast")
    end
    stop = true
    reader.join

    expect(seen).not_to be_empty
    expect(seen.uniq - legit).to eq([])
  end
end
