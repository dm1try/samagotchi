# frozen_string_literal: true

require "samagotchi/effective_model"
require "samagotchi/self_report"
require "samagotchi/send_command"
require "samagotchi/session_setting"
require "samagotchi/session_model_settings"
require "samagotchi/llm_context_override"
require "samagotchi/web/app"
require_relative "support/model_setting_ladders"

# Where each model setting comes from, layer by layer and surface by
# surface (characterization: the goldens in
# spec/fixtures/model_setting_precedence/ were written by the resolvers as
# they were before ModelLookup and must not change with that refactor). Per
# setting, a ladder sets every layer (the session's own, the CLI, the env,
# models: under each lookup name, hosts:, the file key, the API default) to
# its own value and peels them top down; every step records what each
# surface answers.
#
# Regenerate only after an intended behaviour change:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/model_setting_precedence_characterization_spec.rb
RSpec.describe "Model setting precedence (characterization)" do
  include_context "model setting ladders"

  def env_key(key) = Samagotchi::Config::BY_KEY.fetch(key).env_key
  def models(config, key, fields) = (config["models"][key] ||= {}).merge!(fields)
  def host(config, name, fields) = config["hosts"][name].merge!(fields)

  # The start page's picker entry for +name+ (Web::App#add_sampling: its
  # sampling, llm_context and thinking).
  def picker(registry, *names)
    listed = names.map { |name| { name: name } }
    Samagotchi::Web::App.new(registry: registry).send(:add_sampling, listed, registry)
    listed
  end

  def saved_session(typed, **own)
    ModelSettingLadders::SavedSession.new(model_name: typed, model_typed: typed, **own)
  end

  def session_env(vars) = ENV.to_h.merge(vars)

  describe "thinking" do
    it "peels session, CLI, env, models: under each lookup name, hosts:, the file key, default" do
      layers = [
        { name: "session", session: :high },
        { name: "cli", cli: { "thinking.level" => "medium" } },
        { name: "env", env: { env_key("thinking.level") => "low" } },
        { name: "models: small (typed alias)", config: ->(c) { models(c, "small", "thinking" => "off") } },
        { name: "models: box:qwen-a (alias target)", config: ->(c) { models(c, "box:qwen-a", "thinking" => "high") } },
        { name: "models: qwen-a (bare id)", config: ->(c) { models(c, "qwen-a", "thinking" => "medium") } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "thinking" => "low") } },
        { name: "file thinking.level", config: ->(c) { c["thinking"] = { "level" => "off" } } },
        { name: "default" }
      ]
      steps = peel(layers) do |own|
        registry = ladder_registry
        model = effective(registry)
        in_session = own ? { "SAMAGOTCHI_SESSION_MODEL" => "small", "SAMAGOTCHI_SESSION_THINKING" => own.to_s } : {}
        {
          effective: model.thinking_explained(own: own)&.summary,
          effective_level: model.thinking(own: own),
          self_report: Samagotchi::SelfReport.thinking_for("small", ENV),
          self_report_in_session: Samagotchi::SelfReport.thinking_for("small", session_env(in_session)),
          api_models: picker(registry, "small").first[:thinking],
          saved_chip: Samagotchi::SessionSetting::THINKING.saved_summary(saved_session("small", thinking: own),
                                                                         registry: registry)
        }
      end
      expect_ladder_golden("thinking", steps)
    end

    it "takes the most specific lookup name whatever the typed form" do
      every_name = lambda { |c|
        models(c, "small", "thinking" => "off")
        models(c, "box:qwen-a", "thinking" => "high")
        models(c, "qwen-a", "thinking" => "medium")
      }
      rows = %w[small box:qwen-a qwen-a].map do |typed|
        peel([{ name: typed, config: every_name }]) do
          model = effective(ladder_registry, typed)
          { names: model.names, effective: model.thinking_explained(own: nil)&.summary }
        end.first
      end
      expect_ladder_golden("thinking_names", rows)
    end
  end

  describe "reasoning_history" do
    it "peels session, env, models:, hosts:, the api default" do
      layers = [
        { name: "session", session: :all },
        { name: "env", env: { env_key("reasoning_history") => "drop" } },
        { name: "models: small", config: ->(c) { models(c, "small", "reasoning_history" => "turn") } },
        { name: "models: qwen-a", config: ->(c) { models(c, "qwen-a", "reasoning_history" => "all") } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "reasoning_history" => "drop") } },
        { name: "default (api: openai)" }
      ]
      steps = peel(layers) do |own|
        registry = ladder_registry
        model = effective(registry)
        in_session = own ? { "SAMAGOTCHI_SESSION_MODEL" => "small", "SAMAGOTCHI_SESSION_REASONING_HISTORY" => own.to_s } : {}
        {
          effective: model.reasoning_history_explained(own: own)&.summary,
          effective_native: model.reasoning_history_explained(own: own, native: true)&.summary,
          summary: model.reasoning_history_summary(own: own),
          self_report: Samagotchi::SelfReport.reasoning_history_for("small", ENV),
          self_report_in_session: Samagotchi::SelfReport.reasoning_history_for("small", session_env(in_session)),
          saved_chip: Samagotchi::SessionSetting::REASONING_HISTORY.saved_summary(
            saved_session("small", reasoning_history: own), registry: registry
          )
        }
      end
      expect_ladder_golden("reasoning_history", steps)
    end

    it "on a native host resolves only when asked (native: true)" do
      steps = peel([{ name: "models: mod-n", config: ->(c) { models(c, "mod-n", "reasoning_history" => "drop") } },
                    { name: "default (native)" }]) do |own|
        model = effective(ladder_registry(client: ModelSettingLadders::FakeClient.new(nil)), "nat:mod-n")
        { effective: model.reasoning_history_explained(own: own)&.summary,
          effective_native: model.reasoning_history_explained(own: own, native: true)&.summary,
          summary: model.reasoning_history_summary(own: own),
          self_report: Samagotchi::SelfReport.reasoning_history_for("nat:mod-n", ENV) }
      end
      expect_ladder_golden("reasoning_history_native", steps)
    end
  end

  describe "steer_cut_after" do
    it "peels CLI, env, models:, hosts:, the file key, default" do
      layers = [
        { name: "cli (not a layer: masks the file key)", cli: { "steer.cut_after" => 7 } },
        { name: "env", env: { env_key("steer.cut_after") => "5" } },
        { name: "models: small", config: ->(c) { models(c, "small", "steer_cut_after" => 10) } },
        { name: "models: qwen-a", config: ->(c) { models(c, "qwen-a", "steer_cut_after" => 0) } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "steer_cut_after" => 30) } },
        { name: "file steer.cut_after", config: ->(c) { c["steer"] = { "cut_after" => 40 } } },
        { name: "default" }
      ]
      steps = peel(layers) do
        registry = ladder_registry
        settings = Samagotchi::SessionModelSettings.new(
          registry: registry, choice: -> { Samagotchi::ModelChoice.new(name: "small", typed: "small") }, session: -> {}
        )
        { effective: effective(registry).steer_cut_after_explained, summary: settings.steer_cut_summary }
      end
      expect_ladder_golden("steer_cut_after", steps)
    end
  end

  describe "sampling" do
    it "merges hosts: then models: per key" do
      rows = {
        "host only" => ->(c) { host(c, "box", "sampling" => { "temperature" => 0.5, "top_k" => 40 }) },
        "model only" => ->(c) { models(c, "small", "sampling" => { "temperature" => 0.7 }) },
        "both" => lambda { |c|
          host(c, "box", "sampling" => { "temperature" => 0.5, "top_k" => 40 })
          models(c, "qwen-a", "sampling" => { "temperature" => 0.7 })
        },
        "a null key" => lambda { |c|
          host(c, "box", "sampling" => { "temperature" => 0.5, "top_k" => 40 })
          models(c, "small", "sampling" => { "top_k" => nil })
        },
        "none" => ->(_c) {}
      }
      steps = rows.map do |name, config|
        peel([{ name: name, config: config }]) do
          registry = ladder_registry
          model = effective(registry)
          { effective: model.sampling, summary: model.sampling_summary, api_models: picker(registry, "small").first[:sampling] }
        end.first
      end
      expect_ladder_golden("sampling", steps)
    end
  end

  describe "vision (configured)" do
    it "reads models: then hosts:, then asks the adapter" do
      rows = {
        "models false" => ->(c) { models(c, "small", "vision" => false) },
        "models true" => ->(c) { models(c, "qwen-a", "vision" => true) },
        "hosts false" => ->(c) { host(c, "box", "vision" => false) },
        "models true over hosts false" => lambda { |c|
          models(c, "small", "vision" => true)
          host(c, "box", "vision" => false)
        },
        "none" => ->(_c) {}
      }
      steps = rows.map do |name, config|
        peel([{ name: name, config: config }]) do
          registry = ladder_registry
          { effective: effective(registry).vision_support(nil),
            send_command: Samagotchi::SendCommand.vision_answer("small", registry: registry, typed: "small") }
        end.first
      end
      expect_ladder_golden("vision", steps)
    end
  end

  describe "window" do
    it "peels models: under each name, hosts:, then context.window_tokens (CLI, env, file), the default" do
      layers = [
        { name: "models: small", config: ->(c) { models(c, "small", "window_tokens" => 32_768) } },
        { name: "models: qwen-a", config: ->(c) { models(c, "qwen-a", "window_tokens" => 65_536) } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "window_tokens" => 100_000) } },
        { name: "cli", cli: { "context.window_tokens" => 50_000 } },
        { name: "env", env: { env_key("context.window_tokens") => "60000" } },
        { name: "file context.window_tokens", config: ->(c) { c["context"] = { "window_tokens" => 70_000 } } },
        { name: "default" }
      ]
      steps = peel(layers) do
        registry = ladder_registry
        model = effective(registry)
        {
          window_setting: model.window_setting,
          configured_context_window: model.configured_context_window,
          context_window: model.context_window,
          configured: Samagotchi::ContextWindow.configured,
          configured_env: Samagotchi::ContextWindow.configured(env: ENV.to_h),
          self_report: Samagotchi::SelfReport.context_window(ENV, "small")
        }
      ensure
        Samagotchi::ContextWindow.reset!
      end
      expect_ladder_golden("window", steps)
    end

    it "takes the server's and the model list's window over every setting" do
      setting = ->(c) { models(c, "small", "window_tokens" => 32_768) }
      steps = {
        "server n_ctx (native)" => peel([{ name: "server", config: setting }]) do
          effective(ladder_registry(client: ModelSettingLadders::FakeClient.new(40_960)), "nat:mod-n").context_window
        end.first,
        "model list (chat)" => peel([{ name: "model list", config: setting }]) do
          effective(ladder_registry(window: 131_072)).context_window
        end.first
      }
      Samagotchi::ContextWindow.reset!
      expect_ladder_golden("window_server", steps)
    end
  end

  describe "llm_context" do
    def surfaces(own)
      registry = ladder_registry
      session = saved_session("small", llm_context: own)
      {
        effective: effective(registry).llm_context_explained(own&.resolve_args || {})&.summary(own),
        session_budget: Samagotchi::LLMContextStrategy.session_budget(session, registry: registry),
        api_models: picker(registry, "small").first[:llm_context],
        saved_chip: Samagotchi::SessionSetting::LLM_CONTEXT.saved_summary(session, registry: registry)
      }
    end

    it "peels the strategy: session, models:, hosts:, env, the file key, default" do
      layers = [
        { name: "session", session: Samagotchi::LLMContextOverride.new(strategy: [:forget]) },
        { name: "models: small", config: ->(c) { models(c, "small", "llm_context_strategy" => "stale") } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "llm_context_strategy" => "forget") } },
        { name: "env", env: { env_key("llm_context.strategy") => "stale|forget" } },
        { name: "file llm_context.strategy", config: ->(c) { (c["llm_context"] ||= {})["strategy"] = "stale" } },
        { name: "default" }
      ]
      expect_ladder_golden("llm_context_strategy", peel(layers) { |own| surfaces(own) })
    end

    it "peels the apply rule on its own" do
      layers = [
        { name: "session", session: Samagotchi::LLMContextOverride.new(apply: :turn_end) },
        { name: "models: qwen-a", config: ->(c) { models(c, "qwen-a", "llm_context_apply" => "next_request") } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "llm_context_apply" => "turn_end") } },
        { name: "env", env: { env_key("llm_context.apply") => "next_request" } },
        { name: "file llm_context.apply", config: ->(c) { (c["llm_context"] ||= {})["apply"] = "turn_end" } },
        { name: "default" }
      ]
      expect_ladder_golden("llm_context_apply", peel(layers) { |own| surfaces(own) })
    end

    it "peels the budget on its own; the session's off beats a model's budget" do
      layers = [
        { name: "session off", session: Samagotchi::LLMContextOverride.new(budget_tokens: 0) },
        { name: "session", session: Samagotchi::LLMContextOverride.new(budget_tokens: 50_000) },
        { name: "models: small", config: ->(c) { models(c, "small", "llm_context_budget_tokens" => "64k") } },
        { name: "hosts.box", config: ->(c) { host(c, "box", "llm_context_budget_tokens" => 80_000) } },
        { name: "env", env: { env_key("llm_context.budget_tokens") => "90k" } },
        { name: "file llm_context.budget_tokens", config: ->(c) { (c["llm_context"] ||= {})["budget_tokens"] = "100k" } },
        { name: "default" }
      ]
      expect_ladder_golden("llm_context_budget", peel(layers) { |own| surfaces(own) })
    end

    it "resolves each value on its own: a model's strategy with its host's apply rule" do
      steps = peel([{ name: "model strategy, host apply", config: lambda { |c|
        models(c, "small", "llm_context_strategy" => "stale")
        host(c, "box", "llm_context_apply" => "turn_end", "llm_context_budget_tokens" => 80_000)
      } }]) { |own| surfaces(own) }
      expect_ladder_golden("llm_context_mixed", steps)
    end
  end

  describe "profile" do
    def resolution(result) = { name: result.profile.name, source: result.source, detail: result.detail, label: result.label }

    def profile_surfaces
      registry = ladder_registry(client: ModelSettingLadders::FakeClient.new(nil))
      model = effective(registry, "loc")
      {
        model_profile: resolution(Samagotchi::ModelProfile.resolve(names: model.names, entry: model.entry, client: nil,
                                                                   bare_model: model.bare)),
        effective: resolution(model.profile_resolution),
        self_report: Samagotchi::SelfReport.profile_for("loc", ENV)
      }
    end

    def with_loc(config) = config["model_aliases"]["loc"] = "nat:mod-n"

    it "peels CLI, env, models: under each lookup name, hosts:, default" do
      layers = [
        { name: "cli", cli: { "model.profile" => "gemma4" } },
        { name: "env", env: { env_key("model.profile") => "qwen36" } },
        { name: "models: loc (typed alias)", config: ->(c) { models(c, "loc", "profile" => "gemma4") } },
        { name: "models: nat:mod-n (alias target)", config: ->(c) { models(c, "nat:mod-n", "profile" => "qwen36") } },
        { name: "models: mod-n (bare id)", config: ->(c) { models(c, "mod-n", "profile" => "gemma4") } },
        { name: "hosts.nat", config: ->(c) { host(c, "nat", "profile" => "qwen36") } },
        { name: "default", config: ->(c) { with_loc(c) } }
      ]
      expect_ladder_golden("profile", peel(layers) { profile_surfaces })
    end

    it "warns about an unknown profile under the first name and takes the next" do
      warned = []
      allow(Samagotchi::Log).to receive(:warn).and_wrap_original do |original, *args, **kwargs|
        next warned << kwargs[:echo] if args[1] == "unknown_profile"

        original.call(*args, **kwargs)
      end
      steps = peel([{ name: "unknown first, valid second", config: lambda { |c|
        with_loc(c)
        models(c, "loc", "profile" => "bogus")
        models(c, "mod-n", "profile" => "qwen36")
      } }]) { profile_surfaces }
      expect_ladder_golden("profile_unknown", { steps: steps, warnings: warned.uniq })
    end
  end

  describe "warnings" do
    it "names the entry and the field for a bad value in models: and in hosts:" do
      bad = { "vision" => "maybe", "sampling" => "hot", "thinking" => "on", "reasoning_history" => "some",
              "window_tokens" => "big", "steer_cut_after" => "soon", "llm_context_strategy" => "magic",
              "llm_context_apply" => "never", "llm_context_budget_tokens" => "lots" }
      warned = []
      allow(Samagotchi::ConfigFile).to receive(:warn_once) { |message| warned << message }
      peel([{ name: "bad values", config: lambda { |c|
        models(c, "small", bad)
        host(c, "box", bad)
      } }]) do
        model = effective(ladder_registry)
        [model.thinking(own: nil), model.reasoning_history(own: nil), model.sampling, model.window_setting,
         model.steer_cut_after_explained, model.llm_context_explained({}), model.vision_support(nil)]
      end
      expect_ladder_golden("warnings", warned.uniq.sort)
    end
  end

  describe "/api/models when one model's settings fail" do
    it "leaves that model without thinking and llm_context, the others keep theirs" do
      calls = Hash.new(0)
      [Samagotchi::Thinking, Samagotchi::LLMContextStrategy].each do |mod|
        allow(mod).to receive(:explain).and_wrap_original do |original, *args, **kwargs|
          raise IOError, "config gone" if (calls[mod] += 1) == 2

          original.call(*args, **kwargs)
        end
      end
      listed = peel([{ name: "second fails", config: ->(c) { models(c, "small", "thinking" => "low") } }]) do
        picker(ladder_registry, "small", "box:qwen-b", "qwen-a").map { |entry| entry.transform_keys(&:to_s) }
      end
      expect_ladder_golden("api_models_failure", listed)
    end
  end
end
