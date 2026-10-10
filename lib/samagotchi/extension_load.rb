# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "hooks"
require_relative "plugin/loader"

module Samagotchi
  # What an Engine loads from outside chi as it starts: config.yml's hooks,
  # installed bundles' hooks and plugins, and config.yml `bundles:` (their
  # settings). It holds what plugins showed while they loaded (notices,
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
    # hooks config), then the installed bundles' added to them.
    # @return [Hooks::Registry]
    def hooks
      registry = hooks_from_config
      add_bundle_hooks(registry)
      registry
    end

    # Load the installed bundles' plugins into +registries+; one that fails
    # goes to +failures+, and the rest still load.
    def load_plugins(registries, failures:)
      @held_events = []
      @loading = true
      Plugin::Loader.load_installed(registries, failures: failures, settings: bundle_settings)
    ensure
      @loading = false
    end

    # config.yml `bundles:` (ConfigFile.bundle_settings), read once: the
    # bundle hooks and the plugins both want it.
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

    def add_bundle_hooks(registry)
      require_relative "memory_bundle/provenance"
      settings = bundle_settings
      MemoryBundle::Provenance.each_installed(holding: :hooks) do |bundle_name, bundle|
        if bundle.error?
          Log.warn(:hooks, "bundle_manifest_invalid", echo: "[samagotchi:hooks] bundle '#{bundle_name}': #{bundle.error}; its hooks are not loaded",
                                                      bundle: bundle_name)
          @hook_failures.add("hooks (bundle #{bundle_name})", bundle.error, required: false)
          next
        end
        bundle_dir = File.join(MemoryBundle::Provenance.bundles_dir, bundle_name)
        hooks_dir = File.join(bundle_dir, "hooks")
        if bundle.experimental?
          Log.info(:hooks, "experimental_bundle", echo: "[hooks] Bundle '#{bundle_name}' is experimental — its hooks may change or misbehave.", bundle: bundle_name)
        end
        begin
          Hooks::BundleLoader.load(bundle_name: bundle_name, hooks_dir: hooks_dir, metadata: bundle.hooks, registry: registry,
                                   failures: @hook_failures, settings: settings[bundle_name.to_s] || {},
                                   requires_chi: bundle.requires_chi)
        rescue Exception => e # rubocop:disable Lint/RescueException -- a hook's SyntaxError or exit must not stop chi
          raise if e.is_a?(SignalException) # Ctrl-C and kill signals are the user's

          Log.error(:hooks, "bundle_load_failed", echo: "[samagotchi:hooks] bundle '#{bundle_name}' failed to load hooks: #{e.class}: #{e.message}", bundle: bundle_name, error: e.class.name)
        end
      end
    rescue Exception => e # rubocop:disable Lint/RescueException -- a hook's SyntaxError or exit must not stop chi
      raise if e.is_a?(SignalException) # Ctrl-C and kill signals are the user's

      Log.error(:hooks, "bundles_load_failed", echo: "[samagotchi:hooks] failed to load bundle hooks: #{e.class}: #{e.message}", error: e.class.name)
    end
  end
end
