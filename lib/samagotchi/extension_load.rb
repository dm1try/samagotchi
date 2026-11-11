# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "hooks"
require_relative "plugin/loader"

module Samagotchi
  # What an Engine loads from outside chi as it starts: config.yml's hooks,
  # installed bundles' plugins, and config.yml `bundles:` (their settings). It holds what plugins showed while they loaded (notices,
  # cards): no UI is there yet, so the Engine announces them on the first
  # turn (Engine#announce_load_events!).
  class ExtensionLoad
    # @param hook_failures [Guardrails::LoadFailures] where hooks that fail to load go
    def initialize(hook_failures:)
      @hook_failures = hook_failures
      @loading = false
      @held_events = []
    end

    # @return [Array<Hash>] the notices and cards plugins showed while loading
    attr_reader :held_events

    # Whether the plugins are loading now (#load_plugins): what they show
    # then is held (#hold), not shown.
    def loading? = @loading

    # Keep a notice or card a plugin showed while loading.
    # @return [Hash] the event
    def hold(event)
      @held_events << event
      event
    end

    # The hooks: config.yml's (Hooks::Loader; an empty Registry without a
    # hooks config).
    # @return [Hooks::Registry]
    def hooks = hooks_from_config

    # Load the installed bundles' plugins into +registries+; one that fails
    # goes to +failures+, a required one (a guardrail plugin) to the hook
    # failures, where it denies every tool call, and the rest still load.
    # The block runs after them, still loading: what it shows is held with
    # theirs.
    def load_plugins(registries, failures:)
      @held_events = []
      @loading = true
      Plugin::Loader.load_installed(registries, failures: failures, guardrail_failures: @hook_failures, settings: bundle_settings)
                    .tap { yield if block_given? }
    ensure
      @loading = false
    end

    # config.yml `bundles:` (ConfigFile.bundle_settings), read once.
    def bundle_settings
      @bundle_settings ||= Samagotchi::ConfigFile.bundle_settings
    end

    private

    def hooks_from_config
      config_path = Samagotchi::ConfigFile.global_path
      data = Samagotchi::ConfigFile.read_yaml(path: config_path)
      return Hooks::Loader.load(data, failures: @hook_failures) if data.is_a?(Hash)

      Hooks::Registry.new
    end
  end
end
