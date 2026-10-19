# frozen_string_literal: true

require "spec_helper"
require "samagotchi/testing"

# Parity: each shipped bundle with a plugin or hooks registers the same
# things loaded by the kit (its source) as installed by chi and loaded by
# chi's own loaders (Testing::Install: ExtensionLoad's bundle hooks, then
# Plugin::Loader.load_installed).
RSpec.describe "The bundle test kit on the shipped bundles" do
  shipped = Dir[File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, "*", "manifest.yml")].sort.filter_map do |path|
    manifest = Samagotchi::MemoryBundle::Manifest.new(path: path)
    manifest.name if manifest.plugin || manifest.hooks.any?
  end

  # mcp reaches chi.tool_source and chi.init only with a server configured.
  SETTINGS = { "mcp" => { "servers" => { "probe" => { "command" => ["true"] } } } }.freeze

  around { |example| Samagotchi::Testing::Sandbox.with { |sandbox| @sandbox = sandbox; example.run } }

  def installed(name)
    result = Samagotchi::Testing::Install.run(File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, name),
                                              settings: SETTINGS.fetch(name, {}), sandbox: @sandbox)
    expect(result.plugin_failures).to be_empty, "#{name}: #{result.plugin_failures.inspect}"
    result.registered
  end

  def kit(name)
    bundle = Samagotchi::Testing::Bundle.shipped(name, settings: SETTINGS.fetch(name, {}), sandbox: @sandbox)
    Samagotchi::Testing::Install.registered(bundle.registries, name, bundle.inits.map { |init| { label: init.label } })
                                .tap { bundle.shutdown }
  end

  it "covers the shipped bundles with code" do
    expect(shipped).to include("check-in", "known-names", "mcp", "source-links", "claude-peer")
  end

  shipped.each do |name|
    it "loads #{name} as chi does" do
      real = installed(name)
      expect(real.to_h.except(:hooks).values.flatten + real.hooks.values.flatten).not_to be_empty
      expect(kit(name)).to eq(real)
    end
  end
end
