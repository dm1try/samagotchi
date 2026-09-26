# frozen_string_literal: true

require_relative "api"
require_relative "../hooks"
require_relative "../log"
require_relative "../version"
require_relative "../memory_bundle/manifest"
require_relative "../memory_bundle/provenance"

module Samagotchi
  module Plugin
    # What a plugin registers into: an Engine's own registries.
    # +context_for+ is (bundle_name, settings) → the Plugin::Context its
    # handlers get.
    Registries = Struct.new(:commands, :tools, :hooks, :context_for, keyword_init: true)

    # Loads installed bundles' plugins (manifest plugin: {file:, sha256:})
    # into an Engine's registries (docs/plugins.md).
    #
    # For each bundle, by name: the file must match the sha256 recorded at
    # install and chi must meet the bundle's requires_chi. The file is
    # module_eval'd into the bundle's namespace (as its hooks are), the
    # class named like the file (plugin.rb → Plugin) is built with the
    # bundle's settings, and its #register gets a Plugin::Api. What it
    # registered takes effect only when #register returns: a plugin that
    # fails adds nothing.
    #
    # A failure is logged and added to +failures+ (not required: tool calls
    # still run), which the Engine announces once. Not fail-closed.
    module Loader
      TAG = :plugins

      module_function

      # @param registries [Registries]
      # @param failures [Guardrails::LoadFailures, nil]
      # @param settings [Hash{String => Hash}] config.yml `bundles:`
      # @return [Array<String>] the bundles whose plugin loaded
      def load_installed(registries, failures: nil, settings: {})
        loaded = []
        MemoryBundle::Provenance.each_installed_with_plugin do |bundle_name, data|
          ok = load_bundle(bundle_name, data, registries, failures: failures, settings: settings[bundle_name.to_s] || {})
          loaded << bundle_name if ok
        end
        loaded
      rescue StandardError => e
        Log.error(TAG, "plugins_load_failed", echo: "[samagotchi:plugins] failed to load bundle plugins: #{e.class}: #{e.message}",
                                              error: e.class.name)
        loaded || []
      end

      # @return [Boolean] whether the plugin loaded
      def load_bundle(bundle_name, data, registries, failures: nil, settings: {})
        file = MemoryBundle::Provenance.new(name: bundle_name).plugin_path(data) unless data[:error]
        basename = file ? File.basename(file) : "plugin"
        reason = data[:error] || unloadable_reason(file, data)
        return failed(bundle_name, basename, reason, failures) if reason

        plugin = instantiate(bundle_name, file, settings)
        api = Api.new(bundle: bundle_name, label: "#{basename} (bundle #{bundle_name})", registries: registries,
                      context: registries.context_for&.call(bundle_name, settings))
        plugin.register(api)
        api.commit!
        Log.info(TAG, "plugin_loaded", bundle: bundle_name, file: basename, **api.counts)
        true
      rescue Exception => e # rubocop:disable Lint/RescueException -- a plugin's SyntaxError or exit must not stop chi
        raise if e.is_a?(Interrupt)

        failed(bundle_name, basename, "#{e.class}: #{e.message}", failures)
      end

      # Why the installed file can't be loaded, or nil.
      def unloadable_reason(file, data)
        failure = MemoryBundle::Manifest.requires_chi_failure(data[:requires_chi], Samagotchi::VERSION)
        return failure if failure
        return "the file is missing" unless file && File.file?(file)

        Hooks::BundleLoader.sha_mismatch(file, data[:plugin][:sha256], required: true)
      end

      # module_eval the file into a fresh module in the bundle's namespace
      # (Samagotchi::Bundles::<bundle>::PluginLoad<n>: each load gets new
      # classes, not the last load's reopened) and build its class
      # (plugin.rb → Plugin; my_plugin.rb → MyPlugin) as hooks are built:
      # an initialize that takes an argument gets the settings.
      def instantiate(bundle_name, file, settings)
        namespace = fresh_namespace(bundle_name)
        namespace.module_eval(File.read(file), file, 1)
        class_name = File.basename(file, ".rb").split("_").map(&:capitalize).join
        klass = namespace.const_get(class_name, false)
        plugin = Hooks.build_plugin(klass, settings)
        raise ArgumentError, "#{class_name} does not respond to #register" unless plugin.respond_to?(:register)

        plugin
      end

      LOADS = Mutex.new

      def fresh_namespace(bundle_name)
        LOADS.synchronize do
          @loads = (@loads || 0) + 1
          Hooks::BundleLoader.namespace_for(bundle_name).const_set(:"PluginLoad#{@loads}", Module.new)
        end
      end

      def failed(bundle_name, basename, reason, failures)
        Log.warn(TAG, "plugin_not_loaded", echo: "[samagotchi:plugins] bundle '#{bundle_name}' plugin '#{basename}' not loaded: #{reason}",
                                           bundle: bundle_name, file: basename)
        failures&.add("plugin #{basename} (bundle #{bundle_name})", reason, required: false)
        false
      end
    end
  end
end
