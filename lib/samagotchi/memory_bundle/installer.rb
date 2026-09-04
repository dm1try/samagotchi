# frozen_string_literal: true

require "fileutils"
require "digest"
require_relative "provenance"
require_relative "manifest"
require_relative "source"
require_relative "placeholder"
require_relative "index_updater"
require_relative "merger"

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

      attr_reader :results, :warnings, :placeholder_warnings, :conflicts

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

      def initialize(source:, name:, scope: nil, force: false, strict: true, upgrade: false, dry_run: false)
        @source = source
        @name = name
        @scope = scope&.to_s&.strip&.downcase || ""
        @force = force
        @strict = strict
        @upgrade = upgrade
        @dry_run = dry_run
        @results = {}
        @warnings = []
        @placeholder_warnings = []
        @conflicts = {}
        # Propagate scope overrides so IndexUpdater resolves the correct directories.
        IndexUpdater.system_dir_override = self.class.system_dir_override
        IndexUpdater.project_dir_base_override = self.class.project_dir_base_override
      end

      def run
        normalized_dir = nil
        source_owned = false
        manifest = nil
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
        cli_scope = @scope.to_s.strip.empty? ? nil : @scope
        target_scope = cli_scope || manifest&.scope || "system"
        target_dir = resolve_target_dir(target_scope)
        FileUtils.mkdir_p(target_dir)

        # Copy .md files and update index for each.
        all_files_in_bundle = []
        provenance = Provenance.new(name: @name)
        existing_provenance = provenance.read

        Dir.glob(File.join(normalized_dir, "*.md")).each do |file_path|
          file_key = File.basename(file_path)
          all_files_in_bundle << file_key
          target_path = File.join(target_dir, file_key)

          if @upgrade && existing_provenance && !@force && !@dry_run
            # 3-way merge path for upgrades
            base_path = provenance.base_path(file_key)
            classification = Merger.classify(base_path: base_path, current_path: target_path, incoming_path: file_path)
            case classification
            when :install
              FileUtils.cp(file_path, target_path)
              @results[file_key] = { status: "installed" }
              update_target_index(target_scope, target_path, file_key)
            when :fast_forward
              FileUtils.cp(file_path, target_path)
              @results[file_key] = { status: "updated", reason: "auto-merged (not edited)" }
              update_target_index(target_scope, target_path, file_key)
            when :keep
              @results[file_key] = { status: "kept", reason: "bundle unchanged, local edits preserved" }
              update_target_index(target_scope, target_path, file_key)
            when :noop
              @results[file_key] = { status: "skipped", reason: "already up to date" }
              update_target_index(target_scope, target_path, file_key)
            when :conflict
              @results[file_key] = { status: "conflict", reason: "local edits conflict with bundle update" }
              @conflicts[file_key] = { base: base_path, current: target_path, incoming: file_path }
              @warnings << "Conflict in #{file_key}: local edits conflict with bundle update (use --force to overwrite or resolve interactively)"
              update_target_index(target_scope, target_path, file_key)
            end
          elsif @dry_run
            # Dry-run: classify but do not write
            if File.exist?(target_path) && !@force
              if @upgrade && existing_provenance
                base_path = provenance.base_path(file_key)
                classification = Merger.classify(base_path: base_path, current_path: target_path, incoming_path: file_path)
                @results[file_key] = { status: classification.to_s }
                @conflicts[file_key] = { base: base_path, current: target_path, incoming: file_path } if classification == :conflict
              else
                @results[file_key] = { status: "would_skip" }
              end
            else
              @results[file_key] = { status: "would_install" }
            end
          elsif File.exist?(target_path) && !@force
            @results[file_key] = { status: "skipped", reason: "already exists" }
            @warnings << "Skipped #{file_key} (already exists; use --force to overwrite)"
            # Still update the index for skipped files.
            update_target_index(target_scope, target_path, file_key)
          else
            FileUtils.cp(file_path, target_path) unless @dry_run
            @results[file_key] = { status: "installed" }
            # Update index for newly installed files.
            update_target_index(target_scope, target_path, file_key) unless @dry_run
          end
        end
        # Handle pruned files (removed from bundle) — report warnings
        if @upgrade && existing_provenance && existing_provenance[:files]
          existing_provenance[:files].keys.each do |old_key|
            old_key_str = old_key.to_s
            next if all_files_in_bundle.include?(old_key_str) || all_files_in_bundle.include?(old_key.to_s.to_sym.to_s)
            # File was in previous bundle but not in new bundle
            old_target = File.join(target_dir, old_key_str)
            if File.exist?(old_target) && !@dry_run
              base_path = provenance.base_path(old_key_str)
              if File.exist?(base_path) && Merger.current_modified?(base_path, old_target) && !@force
                @warnings << "Bundle no longer includes #{old_key_str} but local file has edits — keeping (use --force to remove)"
                @results[old_key_str] = { status: "kept_pruned", reason: "local edits preserved" } unless @results.key?(old_key_str)
              end
            end
          end
        end

        # Verify checksums if we have a manifest (strict).
        if manifest && @strict
          all_files_in_bundle.each do |file_key|
            next if @conflicts.key?(file_key)
            status = @results[file_key] ? @results[file_key][:status].to_s : nil
            next if %w[kept kept_pruned fast_forward updated].include?(status)
            # For dry-run, fast_forward would appear as "fast_forward", updated not yet
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

        # Write provenance (only if we had a manifest and not dry_run).
        if manifest && !@dry_run
          skip_provenance = @upgrade && @conflicts.any? && !@force
          unless skip_provenance
            provenance_files = {}
            if @upgrade && existing_provenance
              all_files_in_bundle.each do |file_key|
                target_path = File.join(target_dir, file_key)
                next unless File.exist?(target_path)
                status = @results[file_key] ? @results[file_key][:status].to_s : nil
                if %w[kept noop conflict kept_pruned].include?(status)
                  # Keep old base snapshot — do not overwrite with edited current
                  # Use base snapshot as source if it exists to preserve old checksum
                  base_path = provenance.base_path(file_key)
                  if File.exist?(base_path)
                    # Keep existing provenance entry by re-using base content
                    # We still need to include it to prevent pruning, but with base content
                    provenance_files[file_key] = base_path
                  else
                    provenance_files[file_key] = target_path
                  end
                else
                  # installed, updated, skipped — use current target (which is incoming for updated)
                  provenance_files[file_key] = target_path
                end
              end
              # Handle pruned but kept files (bundle removed file but local kept)
              if existing_provenance[:files]
                existing_provenance[:files].keys.each do |old_key|
                  old_key_str = old_key.to_s
                  next if all_files_in_bundle.include?(old_key_str)
                  # If it was kept_pruned, include it with base content to prevent pruning
                  if @results[old_key_str] && @results[old_key_str][:status].to_s == "kept_pruned"
                    base_path = provenance.base_path(old_key_str)
                    target_path = File.join(target_dir, old_key_str)
                    # Use base if exists to keep old checksum, else target
                    src = File.exist?(base_path) ? base_path : target_path
                    provenance_files[old_key_str] = src if File.exist?(src)
                  end
                end
              end
            else
              all_files_in_bundle.each do |file_key|
                target_path = File.join(target_dir, file_key)
                provenance_files[file_key] = target_path if File.exist?(target_path)
              end
            end
            Provenance.new(name: @name).write(
              files: provenance_files,
              scope: target_scope,
              version: manifest.version,
              source_path: @source
            )
          end
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
        installed = @results.select { |_, r| r[:status].to_s == "installed" }.keys
        updated = @results.select { |_, r| r[:status].to_s == "updated" }.keys
        kept = @results.select { |_, r| %w[kept kept_pruned].include?(r[:status].to_s) }.keys
        skipped = @results.select { |_, r| %w[skipped noop would_skip].include?(r[:status].to_s) }.keys
        conflicts = @results.select { |_, r| r[:status].to_s == "conflict" }.keys
        would_install = @results.select { |_, r| r[:status].to_s == "would_install" }.keys
        fast_forward = @results.select { |_, r| r[:status].to_s == "fast_forward" }.keys

        lines << "Installed: #{installed.join(', ')}" unless installed.empty?
        lines << "Updated: #{updated.join(', ')}" unless updated.empty?
        lines << "Would install: #{would_install.join(', ')}" unless would_install.empty?
        lines << "Fast-forward: #{fast_forward.join(', ')}" unless fast_forward.empty?
        lines << "Kept (local edits preserved): #{kept.join(', ')}" unless kept.empty?
        lines << "Skipped: #{skipped.join(', ')}" unless skipped.empty?
        lines << "Conflicts: #{conflicts.join(', ')}" unless conflicts.empty?
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
