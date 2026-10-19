# frozen_string_literal: true

require_relative "../extension_load"
require_relative "../guardrails/load_failures"
require_relative "../memory_bundle/installer"
require_relative "../memory_bundle/provenance"
require_relative "../hooks"
require_relative "bundle"
require_relative "sandbox"
require_relative "recorder"
require_relative "host"

module Samagotchi
  module Testing
    # A bundle as chi installs and loads it, unlike Bundle (its source as it
    # is): MemoryBundle::Installer copies it into the sandbox's state (sha256
    # and requires_chi checked), then chi's own loaders load what is
    # installed (ExtensionLoad: the bundle hooks, then the plugins). What
    # failed names the bundle's source files, not the installed copies.
    #
    #   result = Samagotchi::Testing::Install.run("path/to/bundle", settings: { "every" => 3 })
    #   result.warnings, result.plugin_failures, result.hook_failures, result.registered.commands
    module Install
      # warnings: the Installer's; plugin_failures / hook_failures:
      # [Guardrails::LoadFailures::Failure] of this bundle, each location
      # in the source dir; registered: what it registered (#registered).
      Result = Data.define(:name, :warnings, :plugin_failures, :hook_failures, :registered) do
        def failures = plugin_failures + hook_failures
        def ok? = failures.empty?
      end

      # What a bundle registered (#registered): commands, tools (names),
      # hooks per event, inits (labels), toolkits, tool sources and peer
      # sources (names).
      Registered = Data.define(:commands, :tools, :hooks, :inits, :toolkits, :tool_sources, :peer_sources)
      # A command: its mid_turn policy and its selection-bar labels (chi.annotation).
      Command = Data.define(:name, :mid_turn, :labels)
      # A hook on an event: the bundle, the hook (its file, or the plugin's) and its priority.
      Hook = Data.define(:bundle, :hook, :priority)

      module_function

      # Install the bundle at +dir+ into +sandbox+ (default Sandbox.current,
      # else one of its own, left before returning) and load it.
      # @param settings [Hash] config.yml `bundles: <name>:` (written to the
      #   sandbox's config.yml)
      # @param force [Boolean] the Installer's --force (a name chi ships)
      # @return [Result]
      # @raise [MemoryBundle::Installer::InstallError] what the Installer refused
      def run(dir, settings: {}, sandbox: nil, force: false)
        return Sandbox.with { |own| run(dir, settings: settings, sandbox: own, force: force) } if sandbox.nil? && Sandbox.current.nil?

        sandbox ||= Sandbox.current
        dir = File.expand_path(dir)
        name = MemoryBundle::Manifest.read(dir: dir).name
        sandbox.config("bundles" => { name => settings })
        installer = MemoryBundle::Installer.new(source: dir, name: name, scope: "system", force: force)
        installer.run
        load_installed(name, dir, installer.warnings, sandbox)
      end

      def load_installed(name, dir, warnings, sandbox)
        inits = []
        # A session's values, as an Engine's host gives them (only what the loaders register matters).
        host = Host.build(Recorder.new(cwd: sandbox.work_dir))
        hook_failures = Guardrails::LoadFailures.new
        plugin_failures = Guardrails::LoadFailures.new
        extension = ExtensionLoad.new(hook_failures: hook_failures)
        registries = Plugin::Registries.new(
          commands: SessionCommands.register_builtins(Commands::Registry.new),
          tools: Tools::Builtins.registry, hooks: extension.hooks,
          context_for: lambda { |bundle, bundle_settings, label|
            Plugin::Context.new(bundle: bundle, label: label, settings: bundle_settings, host: host)
          },
          services: Plugin::Services.new, stage_tools: ->(*) {},
          init: ->(_bundle, label, _plugin_label, **, &_block) { inits << { label: label } },
          toolkits: [], tool_index: Tools::ToolIndex.new, peer_sources: PeerSources.new
        )
        extension.load_plugins(registries, failures: plugin_failures)
        installed = File.join(MemoryBundle::Provenance.bundles_dir, name)
        Result.new(name: name, warnings: warnings.dup,
                   plugin_failures: own(plugin_failures, name, installed, dir),
                   hook_failures: own(hook_failures, name, installed, dir),
                   registered: registered(registries, name, inits))
      ensure
        registries&.services&.stop_all
      end
      private_class_method :load_installed

      # What bundle +name+ registered, from the registries it loaded into:
      # hooks per event are Hooks::EVENTS, then any other event the bundle
      # registered for.
      # @param inits [Array<Hash>] {label:} of each chi.init
      # @return [Registered]
      def registered(registries, name, inits)
        Registered.new(
          commands: registries.commands.entries.select { |e| e.source == name }.map do |e|
            Command.new(name: e.name, mid_turn: e.mid_turn, labels: e.annotations.map(&:label))
          end,
          tools: registries.tools.by_source(name).map(&:name),
          hooks: hooks_of(registries.hooks, name),
          inits: inits.map { |init| init[:label] },
          toolkits: Array(registries.toolkits).map(&:name),
          tool_sources: registries.tool_index.sources.map(&:label),
          peer_sources: registries.peer_sources.names
        )
      end

      def hooks_of(hooks, name)
        own = lambda do |event|
          hooks.bundle_hook_names(event).filter_map do |bundle, hook, priority|
            Hook.new(bundle: bundle, hook: hook, priority: priority) if bundle == name
          end
        end
        others = (hooks.bundle_events - Hooks::EVENTS).to_h { |event| [event, own.call(event)] }.reject { |_, list| list.empty? }
        Hooks::EVENTS.to_h { |event| [event, own.call(event)] }.merge(others)
      end
      private_class_method :hooks_of

      # +failures+' entries for bundle +name+, their location moved from the
      # installed copy to the source dir.
      def own(failures, name, installed, dir)
        failures.list.select { |f| f.what.end_with?("(bundle #{name})") }.map do |failure|
          # The plugin is installed into plugin/, the hooks into hooks/.
          location = failure.location&.sub(%r{\A#{Regexp.escape(installed)}/(?:plugin/)?}, "#{dir}/")
          failure.dup.tap { |copy| copy.location = location }
        end
      end
      private_class_method :own
    end
  end
end
