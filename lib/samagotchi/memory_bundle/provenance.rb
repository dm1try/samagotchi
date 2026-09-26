# frozen_string_literal: true

require "json"
require "digest"
require "date"
require "fileutils"
require_relative "../memory_paths"

module Samagotchi
  module MemoryBundle
    # Manages provenance storage at <memories>/.bundles/<name>/ (see MemoryPaths)
    # Each installed bundle gets a directory with:
    #   manifest.json — metadata about the install (merged on reinstall)
    #   bases/        — snapshots of every file as installed (for 3-way merge later)
    class Provenance
      class << self
        attr_accessor :bundles_dir_override

        def bundles_dir
          bundles_dir_override || MemoryPaths.bundles_dir
        end
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

      # The plugin file as installed, or nil when the bundle has none.
      def plugin_path(data = read)
        file = data && data[:plugin].is_a?(Hash) ? data[:plugin][:file].to_s : ""
        file.empty? ? nil : File.join(plugin_dir, file)
      end

      # The plugin's base snapshot (bases/plugin/<file>), for bundle diff.
      def plugin_base_path(file)
        File.join(@bundle_dir, "bases", "plugin", file.to_s)
      end

      # Yields [name, data] for each installed bundle with a plugin, by
      # name. A manifest that doesn't parse is yielded as {error:} when its
      # bundle has a plugin/ dir.
      def self.each_installed_with_plugin
        return enum_for(:each_installed_with_plugin) unless block_given?
        dir = bundles_dir
        return unless Dir.exist?(dir)
        Dir[File.join(dir, "*", "manifest.json")].sort.each do |mjson|
          name = File.basename(File.dirname(mjson))
          begin
            data = JSON.parse(File.read(mjson), symbolize_names: true)
          rescue JSON::ParserError, SystemCallError => e
            yield name, { error: "manifest.json is unreadable: #{e.message}" } if Dir.exist?(File.join(File.dirname(mjson), "plugin"))
            next
          end
          next unless data.is_a?(Hash) && data[:plugin].is_a?(Hash)
          yield name, data
        end
      end

      # Yields [name, data] for each installed bundle with guardrail rule
      # files, by name. A manifest that doesn't parse is yielded as
      # {error:} when its bundle has a guardrails/ dir (its rules can't be
      # checked), and skipped otherwise.
      def self.each_installed_with_guardrails
        return enum_for(:each_installed_with_guardrails) unless block_given?
        dir = bundles_dir
        return unless Dir.exist?(dir)
        Dir[File.join(dir, "*", "manifest.json")].sort.each do |mjson|
          name = File.basename(File.dirname(mjson))
          begin
            data = JSON.parse(File.read(mjson), symbolize_names: true)
          rescue JSON::ParserError, SystemCallError => e
            yield name, { error: "manifest.json is unreadable: #{e.message}" } if Dir.exist?(File.join(File.dirname(mjson), "guardrails"))
            next
          end
          next unless data.is_a?(Hash) && data[:guardrails].is_a?(Hash) && !data[:guardrails].empty?
          yield name, data
        end
      end

      def self.each_installed_holding_hooks
        return enum_for(:each_installed_holding_hooks) unless block_given?
        dir = self.bundles_dir
        return unless Dir.exist?(dir)
        Dir[File.join(dir, "*", "manifest.json")].sort.each do |mjson|
          data = JSON.parse(File.read(mjson), symbolize_names: true)
          next unless data && data[:hooks].is_a?(Hash) && !data[:hooks].empty?
          yield File.basename(File.dirname(mjson)), data
        end
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
      def write(files:, scope:, version:, source_path:, hooks: {}, trust_level: nil, source_commit: nil, hooks_files: {},
                guardrails_files: {}, plugin_file: nil, requires_chi: nil)
        FileUtils.mkdir_p(@bundle_dir)
        bases_dir = File.join(@bundle_dir, "bases")
        FileUtils.mkdir_p(bases_dir)

        # Read existing manifest to merge file entries and find stale files.
        # read symbolizes keys; stringify them so incoming string keys replace
        # them instead of sitting next to them as duplicates.
        existing = read
        merged_entries = existing && existing[:files] ? existing[:files].transform_keys(&:to_s) : {}

        files.each do |file_key, file_path|
          content = File.read(file_path)
          checksum = Digest::SHA256.hexdigest(content)
          # Save base snapshot — use file_key as-is (it already includes .md).
          File.write(File.join(bases_dir, file_key), content)
          merged_entries[file_key] = { checksum: checksum }
        end

        # Prune stale base snapshots for files no longer in the bundle.
        if existing && existing[:files]
          existing[:files].keys.each do |old_key|
            old_key_str = old_key.to_s
            unless files.key?(old_key_str) || files.key?(old_key)
              old_base = File.join(bases_dir, old_key_str)
              FileUtils.rm_f(old_base) if File.exist?(old_base)
              merged_entries.delete(old_key_str)
            end
          end
        end

        # Hooks provenance: persist metadata and base snapshots for hooks
        hooks_map = {}
        # existing hooks for pruning
        existing_hooks = existing && existing[:hooks] ? existing[:hooks] : {}
        # Normalize incoming hooks (basename => metadata hash)
        normalized_hooks = {}
        if hooks.is_a?(Hash)
          hooks.each do |k, v|
            next unless k.is_a?(String) && !k.empty?
            next unless v.is_a?(Hash)
            hv = v.transform_keys(&:to_sym)
            sha = (hv[:sha256] || "").to_s
            sha = sha.start_with?("sha256:") ? sha : "sha256:#{sha}" unless sha.empty?
            normalized_hooks[k] = {
              sha256: sha,
              event: (hv[:event] || "").to_s,
              on_error: (hv[:on_error] || "skip").to_s,
              priority: (hv[:priority] || 100).to_i
            }
          end
        end
        # Prune stale hook bases
        if existing_hooks.is_a?(Hash)
          existing_hooks.keys.each do |old_key|
            old_key_str = old_key.to_s
            unless normalized_hooks.key?(old_key_str) || normalized_hooks.key?(old_key_str.to_sym)
              old_base = File.join(bases_dir, old_key_str)
              FileUtils.rm_f(old_base) if File.exist?(old_base)
            end
          end
        end
        # Save base snapshots for hooks where a file path was provided, and
        # record the sha256 of the installed file itself: the load-time check
        # compares against it, and a declared sha can be wrong (installing
        # only warns about that).
        hooks_files = {} unless hooks_files.is_a?(Hash)
        normalized_hooks.each do |k, meta|
          src = hooks_files[k] || hooks_files[k.to_sym]
          if src && File.exist?(src.to_s)
            meta = meta.merge(sha256: "sha256:#{Digest::SHA256.hexdigest(File.read(src.to_s))}")
          end
          hooks_map[k] = meta.transform_keys(&:to_s)
          if src && File.exist?(src.to_s)
            begin
              File.write(File.join(bases_dir, k), File.read(src.to_s))
            rescue StandardError
              nil
            end
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

        # Write aside and rename, so a reader in another process (a parallel
        # chi start) never parses a truncated manifest.json.
        manifest_path = File.join(@bundle_dir, "manifest.json")
        tmp_path = "#{manifest_path}.#{Process.pid}.tmp"
        File.write(tmp_path, JSON.pretty_generate(manifest_data))
        File.rename(tmp_path, manifest_path)
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path
      end

      # Reads provenance data (returns nil if not installed).
      def read
        manifest_path = File.join(@bundle_dir, "manifest.json")
        return nil unless File.exist?(manifest_path)
        JSON.parse(File.read(manifest_path), symbolize_names: true)
      end

      # Returns the path to a base snapshot for a given file key.
      def base_path(file_key)
        File.join(@bundle_dir, "bases", file_key)
      end

      # Checks whether the bundle is installed.
      def installed?
        read.nil? ? false : true
      end
    end
  end
end
