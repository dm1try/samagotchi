# frozen_string_literal: true

require "samagotchi/bundle_manifest"

# The shipped mcp bundle's plugin evaluated as the loader does it: each of
# its files (manifest.yml plugin: parts:, then plugin.rb, by
# BundleManifest#plugin_files) into one module, each with its own path. Plain
# Ruby, so a spec's subprocess can require it too (mcp_client_spec).
module McpPluginFiles
  DIR = File.expand_path("../../lib/samagotchi/bundles/mcp", __dir__)

  # @return [Module] a fresh module holding Plugin and its parts' classes
  def self.load_module
    Module.new.tap do |mod|
      Samagotchi::BundleManifest.read(dir: DIR).plugin_files.each do |file, _|
        path = File.join(DIR, file)
        mod.module_eval(File.read(path), path, 1)
      end
    end
  end
end
