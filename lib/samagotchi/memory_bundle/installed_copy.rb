# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "bundle_hook"
require_relative "manifest"
require_relative "provenance"

module Samagotchi
  module MemoryBundle
    # An installed bundle laid out as a source folder again: manifest.yml from
    # its record, the plugin, hooks, rules and scripts as they are installed
    # (a dev install's links followed), the memories as their bases (the
    # bundle's bytes, not the user's edits). A bundle's source may be gone or
    # be a URL; this is what `chi update` can check of what really runs.
    #
    # The shas are the files' own, so an edited plugin is checked as written.
    # A plugin, hook or script the record lists that isn't there stays
    # listed, for the check's missing-file.
    module InstalledCopy
      module_function

      # @param bundle [InstalledBundle] a readable one, not a profile
      # @yieldparam dir [String] the folder, removed after the block
      def with(bundle)
        Dir.mktmpdir("chi-installed-copy-") do |tmp|
          dir = File.join(tmp, bundle.name)
          FileUtils.mkdir_p(dir)
          write(bundle, Provenance.new(name: bundle.name), dir)
          yield dir
        end
      end

      def write(bundle, provenance, dir)
        Manifest.write(
          dir: dir, name: bundle.name, version: bundle.version.to_s.empty? ? "0" : bundle.version, trust_level: bundle.trust_level,
          files: memories(bundle, provenance, dir),
          file_descriptions: bundle.files.to_h { |key, entry| [key, entry[:description].to_s] },
          hooks: hooks(bundle, provenance, dir), plugin: plugin(bundle, provenance, dir),
          scripts: copies(bundle.scripts, provenance.scripts_dir, File.join(dir, "scripts")),
          requires_chi: bundle.requires_chi, needs: bundle.needs,
          # A record read with symbol keys: back to what a manifest.yml holds.
          context_providers: JSON.parse(JSON.generate(Array(bundle.context_providers))),
          block_renderers: JSON.parse(JSON.generate(Array(bundle.block_renderers))),
          session_settings: bundle.session_settings, session_setting_types: bundle.session_setting_types,
          settings: bundle.settings, setting_types: bundle.setting_types
        )
        copies(bundle.guardrails, provenance.guardrails_dir, File.join(dir, "guardrails"))
      end
      private_class_method :write

      # A memory with no base has nothing to install, so it isn't listed.
      def memories(bundle, provenance, dir)
        bundle.files.keys.select { |key| File.file?(provenance.base_path(key)) }.to_h do |key|
          [key, copy(provenance.base_path(key), File.join(dir, key), "")]
        end
      end
      private_class_method :memories

      def hooks(bundle, provenance, dir)
        bundle.hooks.to_h do |file, hook|
          sha = copy(File.join(provenance.hooks_dir, file), File.join(dir, "hooks", file), hook.sha256)
          [file, hook.with(sha256: sha)]
        end
      end
      private_class_method :hooks

      def plugin(bundle, provenance, dir)
        return nil unless bundle.plugin

        file = bundle.plugin.file
        { file: file, sha256: copy(provenance.plugin_path(bundle), File.join(dir, file), bundle.plugin.sha256) }
      end
      private_class_method :plugin

      def copies(recorded, from, to)
        recorded.to_h { |file, sha| [file, copy(File.join(from, file), File.join(to, file), sha)] }
      end
      private_class_method :copies

      # @return [String] the sha for the manifest: the copy's, else +recorded+
      def copy(from, to, recorded)
        return recorded unless File.file?(from)

        FileUtils.mkdir_p(File.dirname(to))
        FileUtils.cp(from, to)
        "sha256:#{Provenance.file_sha(to)}"
      end
      private_class_method :copy
    end
  end
end
