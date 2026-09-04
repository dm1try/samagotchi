# frozen_string_literal: true

require "fileutils"
require "digest"
require_relative "provenance"
require_relative "manifest"
require_relative "source"
require_relative "placeholder"
require_relative "index_updater"

module Samagotchi
  module MemoryBundle
    # Installs a bundle into a scoped memories directory.
    #
    # Flow:
    #   1. Normalize source → directory (returns [path, owned])
    #   2. Read manifest.yml
    #   3. Copy .md files to target scope dir (skip or force)
    #   4. Verify checksums (strict mode)
    #   5. Update index.md for each entry
    #   6. Write provenance (.bundles/<name>/)
    #   7. Detect and report {{placeholders}}
    class Installer
      class InstallError < StandardError; end

      attr_reader :results, :warnings, :placeholder_warnings

      DEFAULT_SYSTEM_DIR = File.join(Dir.home, ".config", "samagotchi", "memories")
      DEFAULT_PROJECT_DIR_BASE = File.join(Dir.home, ".config", "samagotchi", "memories", "projects")

      class << self
        attr_accessor :system_dir_override, :project_dir_base_override

        def system_dir
          system_dir_override || DEFAULT_SYSTEM_DIR
        end

        def project_dir_base
          project_dir_base_override || DEFAULT_PROJECT_DIR_BASE
        end
      end

      def initialize(source:, name:, scope: nil, force: false, strict: true)
        @source = source
        @name = name
        @scope = scope&.to_s&.strip&.downcase || ""
        @force = force
        @strict = strict
        @results = {}
        @warnings = []
        @placeholder_warnings = []
        # Propagate scope overrides so IndexUpdater resolves the correct directories.
        IndexUpdater.system_dir_override = self.class.system_dir_override
        IndexUpdater.project_dir_base_override = self.class.project_dir_base_override
      end

      def run
        normalized_dir = nil
        source_owned = false
        begin
          normalized_dir, source_owned = SourceNormalizer.normalize(@source)
          manifest = Manifest.read(dir: normalized_dir)
        rescue SourceNormalizer::UnknownSourceError => e
          raise InstallError, "Source normalization failed: #{e.message}"
        rescue Manifest::ValidationError => e
          if @strict
            raise InstallError, e.message
          else
            @warnings << "No manifest found — proceeding without strict manifest validation"
          end
        end

        # Determine target scope (CLI wins over manifest).
        target_scope = @scope || manifest&.scope || "system"
        target_dir = resolve_target_dir(target_scope)
        FileUtils.mkdir_p(target_dir)

        # Copy .md files and update index for each.
        files_for_provenance = {}
        all_files_in_bundle = []

        Dir.glob(File.join(normalized_dir, "*.md")).each do |file_path|
          file_key = File.basename(file_path)
          all_files_in_bundle << file_key
          target_path = File.join(target_dir, file_key)

          if File.exist?(target_path) && !@force
            @results[file_key] = { status: "skipped", reason: "already exists" }
            @warnings << "Skipped #{file_key} (already exists; use --force to overwrite)"
            # Still update the index for skipped files.
            update_target_index(target_scope, target_path, file_key)
          else
            FileUtils.cp(file_path, target_path)
            @results[file_key] = { status: "installed" }
            files_for_provenance[file_key] = file_path
            # Update index for newly installed files.
            update_target_index(target_scope, target_path, file_key)
          end
        end

        # Verify checksums if we have a manifest (strict).
        if manifest && @strict
          all_files_in_bundle.each do |file_key|
            target_path = File.join(target_dir, file_key)
            next unless File.exist?(target_path)
            expected = manifest.checksum_for(file_key)
            if expected
              actual = Digest::SHA256.hexdigest(File.read(target_path))
              if actual != expected
                @warnings << "Checksum mismatch for #{file_key}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
              end
            end
          end
        end

        # Write provenance (only if we had a manifest).
        # Pass all_files_in_bundle (not just files_for_provenance) so that
        # skipped files also keep their base snapshots on re-install.
        if manifest
          provenance_files = {}
          all_files_in_bundle.each do |file_key|
            target_path = File.join(target_dir, file_key)
            provenance_files[file_key] = target_path if File.exist?(target_path)
          end
          provenance = Provenance.new(name: @name)
          provenance.write(
            files: provenance_files,
            scope: target_scope,
            version: manifest.version,
            source_path: @source
          )
        end

        # Detect placeholders.
        all_files_in_bundle.each do |file_key|
          file_path = File.join(target_dir, file_key)
          next unless File.exist?(file_path)
          names = Placeholder.detect_in_file(file_path)
          if names.any?
            @placeholder_warnings << "#{file_key}: {{#{names.join("}}, {{")}}}"
          end
        end

        [normalized_dir, manifest]
      ensure
        SourceNormalizer.cleanup(normalized_dir) if source_owned
      end

      def summary
        lines = []
        installed = @results.select { |_, r| r[:status] == "installed" }.keys
        skipped = @results.select { |_, r| r[:status] == "skipped" }.keys

        lines << "Installed: #{installed.join(', ')}" unless installed.empty?
        lines << "Skipped: #{skipped.join(', ')}" unless skipped.empty?
        lines.concat(@warnings) unless @warnings.empty?
        lines.concat(@placeholder_warnings) unless @placeholder_warnings.empty?

        lines.any? ? lines.join("\n") : "No files to install."
      end

      private

      def update_target_index(scope, file_path, file_key)
        byte_count = File.exist?(file_path) ? File.size(file_path) : 0
        begin
          IndexUpdater.update_index(scope, file_key, byte_count)
        rescue => _e
          # Silently skip index updates — they're best-effort.
        end
      end

      def resolve_target_dir(scope)
        case scope
        when "system", ""
          self.class.system_dir
        when "project"
          if self.class.project_dir_base_override
            self.class.project_dir_base
          else
            File.join(
              self.class.project_dir_base,
              "#{File.basename(Dir.pwd)}_#{Digest::MD5.hexdigest(Dir.pwd)[0..7]}"
            )
          end
        else
          raise InstallError, "invalid scope: #{scope}"
        end
      end
    end
  end
end
