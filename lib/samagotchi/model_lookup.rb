# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # The layered inputs a model's settings resolve from, in one value: the
  # target (its host entry: the hosts: layer), the names its models: entry
  # may be under (HostRegistry#lookup_names, most specific first), the
  # models: map, and the env the CLI/env/file layers are read with.
  # EffectiveModel builds one per read (with its registry's env); each
  # setting module (Thinking, ReasoningHistory, SteerCutAfter,
  # SamplingSettings, VisionSupport, ContextWindow, LLMContextStrategy) keeps
  # its own ordered resolve over it, and ModelProfile takes its #models.
  #
  # The setting modules call it duck-typed and never name it, and it names
  # none of them (only ModelSettings, ModelSetting, Config, ConfigFile): the
  # modules' parsers are what ModelSettings calls, so either edge would close
  # a cycle (spec/model_lookup_spec.rb checks this file's side).
  #
  # +given_models+ is a caller's models: map (one for a whole picker, or a
  # spec's); without one, #models reads config.yml at each call, as every
  # resolve always did.
  ModelLookup = Data.define(:target, :names, :given_models, :env) do
    # @param target [HostRegistry::ModelTarget, nil] nil: the global layers only
    # @param names [Array<String>] HostRegistry#lookup_names
    # @param models [Hash{String => ModelSettings}, nil] ModelSettings.all by default
    # @param env [Hash] ENV, or another env whose config file and variables
    #   every layer reads (chi self's)
    def self.for(target, names:, models: nil, env: ENV)
      new(target: target, names: Array(names), given_models: models, env: env)
    end

    # The models: map: the one given, else ModelSettings.all for #env; {}
    # when it can't be read.
    # @return [Hash{String => ModelSettings}]
    def models
      return given_models if given_models

      env.equal?(ENV) ? ModelSettings.all : ModelSettings.all(env: env)
    rescue StandardError # degrade-ok: the setting resolves from its other layers, as it always did
      {}
    end

    def entry = target&.entry

    # The host's name, as a "hosts.NAME" label names it.
    def host_name = entry&.name

    # The first lookup name whose models: entry sets +field+ (a
    # ModelSettings member): a ModelSetting (key, value), or nil.
    # @return [ModelSetting, nil]
    def model(field) = ModelSettings.find(names, field, models: models)

    # The host entry's +field+ (a HostEntry member), nil when unset or
    # without a host.
    def host(field) = entry&.public_send(field)

    # [value, origin] of the global config key +key+ (:cli, :env, :file or
    # :default), as Config.get_with_origin gives it; for another env its
    # variables and config file, with this process's CLI settings. Raises as
    # that does.
    # @return [Array(Object, Symbol)]
    def global(key)
      return Config.get_with_origin(key) if env.equal?(ENV)

      file_data = ConfigFile.read_yaml(env: env, path: ConfigFile.global_path(env: env))
      Config.resolve_with_origin(key, file_data: file_data, env: env, cli_overrides: Config.cli_overrides)
    end

    # The model and the names only: the default would print the env (it
    # holds API keys) and the target's client.
    def inspect = "#<Samagotchi::ModelLookup #{target&.model.inspect} host=#{host_name.inspect} names=#{names.inspect}>"
    alias_method :to_s, :inspect
  end
end
