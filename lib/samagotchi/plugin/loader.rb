# frozen_string_literal: true

require_relative "api"
require_relative "context"
require_relative "../hooks"
require_relative "../log"
require_relative "../guardrails/load_failures"
require_relative "../version"
require_relative "../memory_bundle/manifest"
require_relative "../memory_bundle/provenance"

module Samagotchi
  module Plugin
    # What a plugin registers into: an Engine's own registries.
    # +context_for+ is (bundle_name, settings, label) → the Plugin::Context
    # its handlers get; +tools_changed+ drops what was built from the tools
    # (the Engine's system prompts); +services+ (Plugin::Services) is what
    # Engine#shutdown stops; +stage_tools+ is (bundle, specs, context),
    # chi.replace_tools' set, which the Engine applies on its turn thread;
    # +init+ adds a chi.init task (Engine#add_init_task); +toolkits+ is the
    # Engine's list of the plugins' toolkits (chi.toolkit: Toolkit::Kit);
    # +tool_index+ the Engine's Tools::ToolIndex (chi.tool_source);
    # +peer_sources+ the Engine's PeerSources (chi.peer_source).
    Registries = Struct.new(:commands, :tools, :hooks, :context_for, :tools_changed, :services, :stage_tools, :init,
                            :toolkits, :tool_index, :peer_sources, keyword_init: true)

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
        MemoryBundle::Provenance.each_installed(holding: :plugin) do |bundle_name, bundle|
          ok = load_bundle(bundle_name, bundle, registries, failures: failures, settings: settings[bundle_name.to_s] || {})
          loaded << bundle_name if ok
        end
        loaded
      rescue StandardError => e
        Log.error(TAG, "plugins_load_failed", echo: "[samagotchi:plugins] failed to load bundle plugins: #{e.class}: #{e.message}",
                                              error: e.class.name)
        loaded || []
      end

      # @return [Boolean] whether the plugin loaded
      def load_bundle(bundle_name, bundle, registries, failures: nil, settings: {})
        file = MemoryBundle::Provenance.new(name: bundle_name).plugin_path(bundle) unless bundle.error?
        basename = file ? File.basename(file) : "plugin"
        reason = bundle.error || unloadable_reason(file, bundle)
        return failed(bundle_name, basename, reason, failures) if reason

        api = register_file(bundle_name, file, registries, settings: settings)
        Log.info(TAG, "plugin_loaded", bundle: bundle_name, file: basename, **api.counts)
        true
      rescue Exception => e # rubocop:disable Lint/RescueException -- a plugin's SyntaxError or exit must not stop chi
        raise if e.is_a?(SignalException) # Ctrl-C and kill signals are the user's

        failed(bundle_name, basename, "#{e.class}: #{e.message}", failures,
               location: file && Guardrails::LoadFailures.location(e, File.dirname(file)))
      end

      # Build +file+'s plugin with +settings+ and commit what its #register
      # staged into +registries+ (no sha or requires_chi check: #load_bundle
      # makes them; the test kit loads a bundle's source this way).
      # @param namespace [Module, nil] the module the file is evaluated in
      #   (default: a fresh one, #fresh_namespace)
      # @param api_class [Class] what #register gets (Api; the test kit's
      #   recording subclass)
      # @yieldparam plugin [Object] the built plugin, before #register
      # @return [Api] the committed Api (#counts)
      # @raise [Exception] whatever the file, #register or #commit! raised,
      #   after stopping the services it started; nothing is registered
      def register_file(bundle_name, file, registries, settings: {}, namespace: nil, api_class: Api)
        api = nil
        plugin = instantiate(bundle_name, file, settings, namespace: namespace)
        yield plugin if block_given?
        plugin_label = label(bundle_name, File.basename(file))
        api = api_class.new(bundle: bundle_name, label: plugin_label, registries: registries,
                            context: registries.context_for&.call(bundle_name, settings, plugin_label))
        plugin.register(api)
        api.commit!
        api
      rescue Exception # rubocop:disable Lint/RescueException -- stop its services whatever it raised
        api&.abort!
        raise
      end

      # What a plugin's hooks, notices and failures are named by.
      def label(bundle_name, basename) = "#{basename} (bundle #{bundle_name})"

      # Why the installed file can't be loaded, or nil.
      def unloadable_reason(file, bundle)
        failure = MemoryBundle::Manifest.requires_chi_failure(bundle.requires_chi, Samagotchi::VERSION)
        return failure if failure
        return "the file is missing" unless file && File.file?(file)

        Hooks::BundleLoader.sha_mismatch(file, bundle.plugin.sha256, required: true)
      end

      # module_eval the file into a fresh module in the bundle's namespace
      # (Samagotchi::Bundles::<bundle>::PluginLoad<n>: each load gets new
      # classes, not the last load's reopened) and build its class
      # (plugin.rb → Plugin; my_plugin.rb → MyPlugin) as hooks are built:
      # an initialize that takes an argument gets the settings.
      def instantiate(bundle_name, file, settings, namespace: nil)
        namespace ||= fresh_namespace(bundle_name)
        namespace.module_eval(File.read(file), file, 1)
        klass = Hooks.class_for(file, namespace)
        plugin = Hooks.build_plugin(klass, settings)
        raise ArgumentError, "#{klass.name.split("::").last} does not respond to #register" unless plugin.respond_to?(:register)

        plugin
      end

      LOADS = Mutex.new

      def fresh_namespace(bundle_name)
        LOADS.synchronize do
          @loads = (@loads || 0) + 1
          Hooks::BundleLoader.namespace_for(bundle_name).const_set(:"PluginLoad#{@loads}", Module.new)
        end
      end

      def failed(bundle_name, basename, reason, failures, location: nil)
        Log.warn(TAG, "plugin_not_loaded", echo: "[samagotchi:plugins] bundle '#{bundle_name}' plugin '#{basename}' not loaded: #{reason}",
                                           bundle: bundle_name, file: basename)
        failures&.add("plugin #{basename} (bundle #{bundle_name})", reason, required: false, location: location)
        false
      end
    end
  end
end
