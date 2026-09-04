# frozen_string_literal: true

require "json"
require "digest"
require "date"
require "fileutils"

module Samagotchi
  module MemoryBundle
    # Manages provenance storage at ~/.config/samagotchi/memories/.bundles/<name>/
    # Each installed bundle gets a directory with:
    #   manifest.json — metadata about the install (merged on reinstall)
    #   bases/        — snapshots of every file as installed (for 3-way merge later)
    class Provenance
      DEFAULT_BUNDLES_DIR = File.join(Dir.home, ".config", "samagotchi", "memories", ".bundles")

      class << self
        attr_accessor :bundles_dir_override

        def bundles_dir
          bundles_dir_override || DEFAULT_BUNDLES_DIR
        end
      end

      attr_reader :name, :bundle_dir

      def initialize(name:)
        @name = name
        @bundle_dir = File.join(self.class.bundles_dir, name)
      end

      # Writes provenance for an installation: merges into existing manifest.json
      # and saves base snapshots. Stale base snapshots (files removed from bundle)
      # are pruned.
      def write(files:, scope:, version:, source_path:)
        FileUtils.mkdir_p(@bundle_dir)
        bases_dir = File.join(@bundle_dir, "bases")
        FileUtils.mkdir_p(bases_dir)

        # Read existing manifest to merge file entries and find stale files.
        existing = read
        merged_entries = existing && existing[:files] ? existing[:files].dup : {}

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
              merged_entries.delete(old_key)
            end
          end
        end

        manifest_data = {
          "name" => @name,
          "version" => version.to_s,
          "scope" => scope.to_s,
          "source" => source_path.to_s,
          "installed_at" => DateTime.now.iso8601,
          "files" => merged_entries
        }

        File.write(File.join(@bundle_dir, "manifest.json"), JSON.pretty_generate(manifest_data))
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
