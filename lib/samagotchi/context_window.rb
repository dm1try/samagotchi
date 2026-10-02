# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # The model's context window in tokens, and where that number came from.
  #
  # Lookup order:
  #   1. the running server (Client#context_window, e.g. llama.cpp's n_ctx)
  #   2. the host's model list (a chat adapter's #context_window, e.g. a
  #      provider's context_length)
  #   3. models.<key>.window_tokens, else hosts.<name>.window_tokens
  #      (#setting: the most specific wins)
  #   4. context.window_tokens (CLI, SAMAGOTCHI_CONTEXT_WINDOW_TOKENS or the
  #      config file)
  #   5. DEFAULT_TOKENS
  # Settings (3 and 4) only fill in when the server and its list report
  # nothing.
  #
  # Sources: :server, :model_list, :model_setting, :host_setting, :config
  # (CLI or file), :env, :default.
  module ContextWindow
    DEFAULT_TOKENS = 256_000

    Resolved = Struct.new(:tokens, :source, keyword_init: true)

    module_function

    # @param adapter [#context_window, nil] the host's chat adapter
    # @param setting [Resolved, nil] the model's or host's window (#setting)
    def resolve(client: nil, model: nil, adapter: nil, setting: nil)
      server_tokens = client.context_window(model: model) if client.respond_to?(:context_window)
      if positive_integer?(server_tokens)
        @last_server = Resolved.new(tokens: server_tokens, source: :server)
        return @last_server
      end

      listed = adapter.context_window(model: model) if adapter.respond_to?(:context_window)
      if positive_integer?(listed)
        @last_server = Resolved.new(tokens: listed, source: :model_list)
        return @last_server
      end
      return @last_server = setting if setting

      configured
    end

    # The window config.yml gives this model or its host:
    # models.<key>.window_tokens (by the model's lookup names, as sampling
    # and vision look a model up), else hosts.<name>.window_tokens.
    # @param target [HostRegistry::ModelTarget]
    # @param names [Array<String>] HostRegistry#lookup_names
    # @param models [Hash, nil] ConfigFile.model_settings (specs)
    # @return [Resolved, nil]
    def setting(target, names:, models: nil)
      models ||= ConfigFile.model_settings
      _key, tokens = ConfigFile.model_setting(names, :window_tokens, models: models)
      return Resolved.new(tokens: tokens, source: :model_setting) if positive_integer?(tokens)

      tokens = target&.entry&.window_tokens
      positive_integer?(tokens) ? Resolved.new(tokens: tokens, source: :host_setting) : nil
    rescue StandardError
      nil
    end

    # The window without asking a server: config, env, then the default.
    # `env` resolves against that env's config file instead of the live
    # process config (for `chi self`).
    def configured(env: nil)
      value, origin = begin
        if env
          file_data = ConfigFile.read_yaml(path: ConfigFile.global_path(env: env))
          Config.resolve_with_origin("context.window_tokens", file_data: file_data, env: env)
        else
          Config.get_with_origin("context.window_tokens")
        end
      rescue StandardError
        [nil, :default]
      end
      return Resolved.new(tokens: DEFAULT_TOKENS, source: :default) unless positive_integer?(value)

      Resolved.new(tokens: value, source: origin == :env ? :env : :config)
    end

    # For callers with no client at hand (tool output guardrails): the last
    # window a server reported in this process, else #configured. With
    # several hosts in one process this can be another host's window, which
    # is good enough for a size heuristic.
    def current
      @last_server || configured
    end

    def reset!
      @last_server = nil
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end
  end
end
