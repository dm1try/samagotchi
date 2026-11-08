# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require_relative "manifest"
require_relative "provenance"

module Samagotchi
  module MemoryBundle
    # An installed bundle laid out as a source folder again: the plugin,
    # rules and scripts as they are installed (a dev install's links
    # followed), the memories as their bases (the bundle's bytes, not the
    # user's edits). A bundle's source may be gone or be a URL; this is what
    # `chi update` can check of what really runs.
    #
    # manifest.yml: its files:, plugin: and scripts: are the record's and
    # the copy's (what is installed: a memory the install left out, or one
    # with no base, isn't listed, so the check finds no missing-file for it).
    # It has no hooks: and no hooks/, whatever the record or the kept
    # manifest says: class-file hooks don't load (InstalledCheck names a
    # record's once). Every other key is the kept
    # manifest.yml's when it is read (InstalledManifest origin :kept), so the
    # check sees its unknown keys too; else the record's mirror's.
    #
    # The shas are the files' own, so an edited plugin is checked as written.
    # A plugin or script the record lists that isn't there stays
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
        manifest = bundle.manifest
        Manifest.write(
          dir: dir, name: bundle.name, version: bundle.version.to_s.empty? ? "0" : bundle.version, trust_level: manifest.trust_level,
          files: memories(bundle, provenance, dir),
          file_descriptions: manifest.file_descriptions,
          plugin: plugin(bundle, provenance, dir),
          scripts: copies(bundle.scripts, provenance.scripts_dir, File.join(dir, "scripts")),
          requires_chi: manifest.requires_chi, needs: manifest.needs,
          context_providers: manifest.context_providers, block_renderers: manifest.block_renderers,
          session_settings: manifest.session_settings, session_setting_types: manifest.session_setting_types,
          settings: manifest.settings, setting_types: manifest.setting_types
        )
        keep_manifest_keys(bundle.kept_manifest_path, File.join(dir, "manifest.yml"), manifest.key_problems.keys) if manifest.origin == :kept
        copies(bundle.guardrails, provenance.guardrails_dir, File.join(dir, "guardrails"))
      end
      private_class_method :write

      # What is installed, which the copy's manifest.yml takes from the
      # record (hooks: none, so the kept manifest's isn't taken either).
      INSTALLED_KEYS = %w[name version files hooks plugin scripts].freeze

      # The written manifest's INSTALLED_KEYS and +failed+ keys (the value
      # InstalledManifest fell back to: InstalledCheck already names the
      # problem, and the raw value would name it again), then the kept
      # manifest's other keys. A kept file of comments only holds none.
      def keep_manifest_keys(kept, written, failed)
        ours = YAML.load_file(written)
        theirs = YAML.load_file(kept) || {}
        own = INSTALLED_KEYS + failed
        File.write(written, YAML.dump(ours.slice(*own).merge(theirs.except(*own))))
      end
      private_class_method :keep_manifest_keys

      # A memory with no base has nothing to install, so it isn't listed.
      def memories(bundle, provenance, dir)
        bundle.files.keys.select { |key| File.file?(provenance.base_path(key)) }.to_h do |key|
          [key, copy(provenance.base_path(key), File.join(dir, key), "")]
        end
      end
      private_class_method :memories

      def plugin(bundle, provenance, dir)
        return nil unless bundle.plugin

        file = bundle.plugin.file
        { file: file, sha256: copy(provenance.plugin_path(bundle), File.join(dir, file), bundle.plugin.sha256),
          required: bundle.manifest.plugin_required }
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
