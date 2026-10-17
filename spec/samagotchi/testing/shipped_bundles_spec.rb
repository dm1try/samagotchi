# frozen_string_literal: true

require "spec_helper"
require "samagotchi/testing"
require "samagotchi/extension_load"
require "samagotchi/guardrails/load_failures"
require "samagotchi/memory_bundle/installer"

# Parity: each shipped bundle with a plugin or hooks registers the same
# things loaded by the kit (its source) as installed by chi and loaded by
# chi's own loaders (ExtensionLoad: the bundle hooks, then
# Plugin::Loader.load_installed).
RSpec.describe "The bundle test kit on the shipped bundles" do
  shipped = Dir[File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, "*", "manifest.yml")].sort.filter_map do |path|
    manifest = Samagotchi::MemoryBundle::Manifest.new(path: path)
    manifest.name if manifest.plugin || manifest.hooks.any?
  end

  # mcp reaches chi.tool_source and chi.init only with a server configured.
  SETTINGS = { "mcp" => { "servers" => { "probe" => { "command" => ["true"] } } } }.freeze

  around { |example| Samagotchi::Testing::Sandbox.with { |sandbox| @sandbox = sandbox; example.run } }

  # Every event a hook can be registered for (docs/hooks.md).
  EVENTS = %i[session_start before_turn before_generation generation_progress after_generation before_tool_call
              after_tool_call after_turn session_end].freeze

  # What a bundle registered, from the registries it loaded into.
  def registered(registries, name, inits)
    {
      commands: registries.commands.entries.select { |e| e.source == name }.map { |e| [e.name, e.mid_turn, e.annotations.map(&:label)] },
      tools: registries.tools.by_source(name).map(&:name),
      hooks: EVENTS.to_h { |event| [event, registries.hooks.bundle_hook_names(event).select { |b, _, _| b == name }] },
      inits: inits.map { |init| init[:label] },
      toolkits: Array(registries.toolkits).map(&:name),
      tool_sources: registries.tool_index.sources.map(&:label),
      peer_sources: registries.peer_sources.names
    }
  end

  def installed(name)
    @sandbox.config("bundles" => SETTINGS.slice(name))
    Samagotchi::MemoryBundle::Installer.new(source: File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, name), name: name,
                                            scope: "system").run
    inits = []
    # A session's values, as an Engine's host gives them (only the loaders are compared).
    host = Samagotchi::Testing::Host.build(Samagotchi::Testing::Recorder.new(cwd: @sandbox.work_dir))
    extension = Samagotchi::ExtensionLoad.new(hook_failures: Samagotchi::Guardrails::LoadFailures.new)
    plugin_failures = Samagotchi::Guardrails::LoadFailures.new
    registries = Samagotchi::Plugin::Registries.new(
      commands: Samagotchi::SessionCommands.register_builtins(Samagotchi::Commands::Registry.new),
      tools: Samagotchi::Tools::Builtins.registry, hooks: extension.hooks,
      context_for: lambda { |bundle, settings, label|
        Samagotchi::Plugin::Context.new(bundle: bundle, label: label, settings: settings, host: host)
      },
      services: Samagotchi::Plugin::Services.new, stage_tools: ->(*) {},
      init: ->(_bundle, label, _plugin_label, **, &_block) { inits << { label: label } },
      toolkits: [], tool_index: Samagotchi::Tools::ToolIndex.new, peer_sources: Samagotchi::PeerSources.new
    )
    extension.load_plugins(registries, failures: plugin_failures)
    expect(plugin_failures.any?).to be(false), "#{name}: #{plugin_failures.inspect}"
    registered(registries, name, inits).tap { registries.services.stop_all }
  end

  def kit(name)
    bundle = Samagotchi::Testing::Bundle.shipped(name, settings: SETTINGS.fetch(name, {}), sandbox: @sandbox)
    registered(bundle.registries, name, bundle.inits.map { |init| { label: init.label } }).tap { bundle.shutdown }
  end

  it "covers the shipped bundles with code" do
    expect(shipped).to include("check-in", "known-names", "mcp", "source-links", "claude-peer")
  end

  shipped.each do |name|
    it "loads #{name} as chi does" do
      real = installed(name)
      expect(real.values_at(:commands, :tools, :inits, :toolkits, :tool_sources, :peer_sources).flatten +
             real[:hooks].values.flatten).not_to be_empty
      expect(kit(name)).to eq(real)
    end
  end
end
