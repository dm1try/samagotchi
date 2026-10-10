# frozen_string_literal: true

require "json"
require "digest"
require "date"
require "fileutils"
require_relative "../atomic_file"
require_relative "../memory_paths"
require_relative "bundle_hook"
require_relative "installed_bundle"

module Samagotchi
  module MemoryBundle
    # Manages provenance storage at <memories>/.bundles/<name>/ (see MemoryPaths)
    # Each installed bundle gets a directory with:
    #   manifest.json — metadata about the install (merged on reinstall)
    #   bases/        — snapshots of every file as installed (for 3-way merge later)
    class Provenance
      def self.bundles_dir
        MemoryPaths.bundles_dir
      end

      attr_reader :name, :bundle_dir

      def initialize(name:)
        @name = name
        @bundle_dir = File.join(self.class.bundles_dir, name)
      end

      def hooks_dir
        File.join(@bundle_dir, "hooks")
      end

      # Installed guardrail rule files (guardrails/*.yml).
      def guardrails_dir
        File.join(@bundle_dir, "guardrails")
      end

      # The installed plugin file's dir (plugin/<file>).
      def plugin_dir
        File.join(@bundle_dir, "plugin")
      end

      # The installed scripts' dir (scripts/<file>): what a context
      # provider's command finds as {bundle_dir}/scripts.
      def scripts_dir
        File.join(@bundle_dir, "scripts")
      end

      # The plugin file as installed, or nil when the bundle has none.
      # @param bundle [InstalledBundle, nil] its record (read when not given)
      def plugin_path(bundle = record)
        file = bundle&.plugin&.file
        file ? File.join(plugin_dir, file) : nil
      end

      # The plugin's base snapshot (bases/plugin/<file>), for bundle diff.
      def plugin_base_path(file)
        File.join(@bundle_dir, "bases", "plugin", file.to_s)
      end

      # Yields [name, bundle] for each installed bundle (a dir under
      # bundles_dir holding a manifest.json, dot dirs aside), by name. bundle
      # is its InstalledBundle, one with error set when manifest.json doesn't
      # parse or isn't an object; the rest still come.
      #
      # With holding: (:hooks, :guardrails or :plugin) only the bundles
      # whose manifest has a non-empty mapping under that key come, and a
      # manifest that doesn't parse comes (with error) only when its bundle
      # has that dir (hooks/, guardrails/, plugin/): what it would load
      # can't be checked. One that isn't an object is skipped there.
      # @param dir [String] the bundles dir (bundles_dir by default)
      def self.each_installed(holding: nil, dir: bundles_dir)
        return enum_for(:each_installed, holding: holding, dir: dir) unless block_given?
        return unless Dir.exist?(dir)

        Dir.children(dir).reject { |e| e.start_with?(".") }.sort.each do |name|
          mjson = File.join(dir, name, "manifest.json")
          next unless File.exist?(mjson)

          begin
            data = JSON.parse(File.read(mjson), symbolize_names: true)
          rescue JSON::ParserError, SystemCallError => e
            if holding.nil? || Dir.exist?(File.join(dir, name, holding.to_s))
              yield name, InstalledBundle.unreadable(name, "manifest.json is unreadable: #{e.message}")
            end
            next
          end
          next if holding && !(data.is_a?(Hash) && data[holding].is_a?(Hash) && !data[holding].empty?)

          yield name, InstalledBundle.parse(name, data)
        end
      end

      # The other installed bundles of +scope+ whose record lists the memory
      # file +file_key+, by name (a manifest that doesn't read is left out).
      # A project-scoped record doesn't say which project: one from another
      # repo counts too, which errs on keeping the file.
      def self.claimants(file_key, scope:, except: nil, dir: bundles_dir)
        each_installed(dir: dir).filter_map do |name, bundle|
          next if name == except || bundle.error?
          next unless bundle.effective_scope == scope.to_s && bundle.owns?(file_key)

          name
        end
      end

      # The hex digest a manifest records, in either of its formats:
      # "sha256:<hex>" (hooks, rules, the plugin) or bare <hex> (a memory
      # file's checksum:). "" when none is recorded.
      def self.recorded_sha(value)
        value.to_s.delete_prefix("sha256:")
      end

      def self.file_sha(path)
        Digest::SHA256.hexdigest(File.binread(path))
      end

      # Whether the file's content is the one recorded (either format).
      def self.sha_matches?(path, recorded)
        file_sha(path) == recorded_sha(recorded)
      end

      # Writes provenance for an installation: merges into existing manifest.json
      # and saves base snapshots. Stale base snapshots (files removed from bundle)
      # are pruned.
      # @param hooks_files [Hash] basename => path for hook file snapshots (optional)
      # @param guardrails_files [Hash] basename => installed rule file; the
      #   sha256 of each is recorded (the Engine checks it at load)
      # @param plugin_file [String, nil] the installed plugin file; its name
      #   and sha256 are recorded (the Engine checks it at load) with a base
      #   snapshot
      # @param requires_chi [String, nil] the manifest's requirement
      # @param needs [Array<Hash>] the manifest's needs ({command:, why:, hint:})
      # @param conflicts [Array<String>] files an upgrade kept with local
      #   edits that conflict with it; their entries get conflict: true
      # @param includes [Array<String>, nil] a profile's recorded members
      #   (MemoryBundle::Profile); nil for a plain bundle
      # @param scripts_files [Hash] file name => installed script; the
      #   sha256 of each is recorded (ContextFetch checks it before a run)
      # @param context_providers [Array<ContextProviders::Provider>]
      def write(files:, scope:, version:, source_path:, hooks: {}, trust_level: nil, source_commit: nil, hooks_files: {},
                guardrails_files: {}, plugin_file: nil, requires_chi: nil, needs: nil, conflicts: [], includes: nil,
                scripts_files: {}, context_providers: [], file_descriptions: {})
        FileUtils.mkdir_p(@bundle_dir)
        bases_dir = File.join(@bundle_dir, "bases")
        FileUtils.mkdir_p(bases_dir)

        # The existing record: its file entries merge with these, and its
        # files and hooks not in this install are stale.
        existing = record
        merged_entries = existing ? existing.files.dup : {}

        files.each do |file_key, file_path|
          content = File.read(file_path)
          checksum = Digest::SHA256.hexdigest(content)
          # Save base snapshot — use file_key as-is (it already includes .md).
          File.write(File.join(bases_dir, file_key), content)
          merged_entries[file_key] = { checksum: checksum }
          merged_entries[file_key][:conflict] = true if conflicts.include?(file_key.to_s)
          merged_entries[file_key][:description] = file_descriptions[file_key.to_s] if file_descriptions[file_key.to_s]
        end

        # Prune stale base snapshots for files no longer in the bundle.
        if existing
          existing.files.each_key do |old_key_str|
            next if files.key?(old_key_str) || files.key?(old_key_str.to_sym)

            old_base = File.join(bases_dir, old_key_str)
            FileUtils.rm_f(old_base)
            merged_entries.delete(old_key_str)
          end
        end

        # Hooks provenance: persist metadata and base snapshots for hooks
        hooks_map = {}
        # Incoming hooks: basename => BundleHook (or its metadata hash)
        normalized_hooks = {}
        if hooks.is_a?(Hash)
          hooks.each do |k, v|
            next unless k.is_a?(String) && !k.empty?
            next unless v.is_a?(Hash) || v.is_a?(BundleHook)

            normalized_hooks[k] = BundleHook.parse(v)
          end
        end
        # Prune stale hook bases
        existing&.hooks&.each_key do |old_key_str|
          FileUtils.rm_f(File.join(bases_dir, old_key_str)) unless normalized_hooks.key?(old_key_str)
        end
        # Save base snapshots for hooks where a file path was provided, and
        # record the sha256 of the installed file itself: the load-time check
        # compares against it, and a declared sha can be wrong (installing
        # only warns about that).
        hooks_files = {} unless hooks_files.is_a?(Hash)
        normalized_hooks.each do |k, hook|
          src = hooks_files[k] || hooks_files[k.to_sym]
          hook = hook.with(sha256: BundleHook.of_file(src.to_s).sha256) if src && File.exist?(src.to_s)
          hooks_map[k] = hook.to_record
          next unless src && File.exist?(src.to_s)

          begin
            File.write(File.join(bases_dir, k), File.read(src.to_s))
          rescue StandardError
            nil
          end
        end

        manifest_data = {
          "name" => @name,
          "version" => version.to_s,
          "scope" => scope.to_s,
          "source" => source_path.to_s,
          "installed_at" => DateTime.now.iso8601,
          "files" => merged_entries,
          "hooks" => hooks_map
        }
        manifest_data["trust_level"] = trust_level.to_s if trust_level && !trust_level.to_s.empty?
        if guardrails_files.is_a?(Hash) && !guardrails_files.empty?
          manifest_data["guardrails"] = guardrails_files.sort.to_h do |basename, path|
            [basename.to_s, { "sha256" => "sha256:#{Digest::SHA256.hexdigest(File.read(path.to_s))}" }]
          end
        end
        manifest_data["source_commit"] = source_commit.to_s if source_commit && !source_commit.to_s.empty?
        FileUtils.rm_rf(File.join(bases_dir, "plugin"))
        if plugin_file
          content = File.binread(plugin_file.to_s)
          manifest_data["plugin"] = { "file" => File.basename(plugin_file.to_s),
                                      "sha256" => "sha256:#{Digest::SHA256.hexdigest(content)}" }
          FileUtils.mkdir_p(File.join(bases_dir, "plugin"))
          File.binwrite(plugin_base_path(File.basename(plugin_file.to_s)), content)
        end
        manifest_data["requires_chi"] = requires_chi.to_s if requires_chi && !requires_chi.to_s.empty?
        manifest_data["needs"] = needs.map { |n| n.transform_keys(&:to_s).compact } if needs.is_a?(Array) && !needs.empty?
        manifest_data["includes"] = includes.map(&:to_s) if includes.is_a?(Array)
        unless scripts_files.empty?
          manifest_data["scripts"] = scripts_files.sort.to_h do |file, path|
            [file.to_s, { "sha256" => "sha256:#{Digest::SHA256.hexdigest(File.binread(path.to_s))}" }]
          end
        end
        manifest_data["context_providers"] = context_providers.map(&:to_h) unless context_providers.empty?

        write_manifest(manifest_data)
      end

      # After a conflict was resolved by hand: each file's base becomes the
      # bundle's version (the incoming file, else what's on disk now) and
      # its conflict mark goes. The rest of the manifest stays as is.
      # @param conflicts [Hash{String => Hash}] Installer#conflicts
      def resolve_conflicts(conflicts)
        return unless installed?

        raw = JSON.parse(File.read(File.join(@bundle_dir, "manifest.json")))
        raw["files"] ||= {}
        conflicts.each do |file_key, info|
          key = file_key.to_s
          next unless raw["files"].key?(key)

          src = [info[:incoming], info[:current]].find { |p| p && File.exist?(p) }
          next unless src

          content = File.read(src)
          File.write(base_path(key), content)
          raw["files"][key] = { "checksum" => Digest::SHA256.hexdigest(content) }
        end
        write_manifest(raw)
      end

      # The installed bundle's record, nil when it isn't installed.
      # @return [InstalledBundle, nil]
      # @raise [JSON::ParserError] manifest.json doesn't parse
      def record
        InstalledBundle.read(@name, File.join(@bundle_dir, "manifest.json"))
      end

      # manifest.json as it is on disk, symbol keys (nil if not installed).
      # Readers take #record.
      def read
        manifest_path = File.join(@bundle_dir, "manifest.json")
        return nil unless File.exist?(manifest_path)

        JSON.parse(File.read(manifest_path), symbolize_names: true)
      end

      # Write aside and rename, so a reader in another process (a parallel
      # chi start) never parses a truncated manifest.json.
      def write_manifest(manifest_data)
        manifest_path = File.join(@bundle_dir, "manifest.json")
        AtomicFile.write(manifest_path, JSON.pretty_generate(manifest_data))
      end
      private :write_manifest

      # Returns the path to a base snapshot for a given file key.
      def base_path(file_key)
        File.join(@bundle_dir, "bases", file_key)
      end

      # Checks whether the bundle is installed.
      def installed?
        !record.nil?
      end
    end
  end
end
