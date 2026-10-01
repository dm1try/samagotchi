# frozen_string_literal: true

require "fileutils"
require "digest"
require_relative "../memory_paths"
require_relative "provenance"
require_relative "manifest"
require_relative "source"
require_relative "placeholder"
require_relative "index_updater"
require_relative "merger"
require_relative "../version"
require_relative "../bundle_needs"

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
      end

      def run
        normalized_dir = nil
        source_owned = false
        source_commit = nil
        manifest = nil
        begin
          normalized_dir, source_owned, source_commit = SourceNormalizer.normalize(@source)
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
        # A plain install over an installed bundle: summary points at upgrade.
        @reinstall = existing_provenance && !@upgrade && !@force && !@dry_run

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
              elsif FileUtils.identical?(file_path, target_path)
                @results[file_key] = { status: "skipped", reason: "already up to date" }
              else
                @results[file_key] = { status: "would_skip" }
              end
            else
              @results[file_key] = { status: "would_install" }
            end
          elsif File.exist?(target_path) && !@force && FileUtils.identical?(file_path, target_path)
            @results[file_key] = { status: "skipped", reason: "already up to date" }
            update_target_index(target_scope, target_path, file_key)
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

        # ── Hooks: copy hooks/*.rb into <bundle_dir>/hooks/ ───────────────
        hooks_target = File.join(provenance.bundle_dir, "hooks")
        all_hooks_in_bundle = []
        hooks_files_for_provenance = {}
        if manifest
          hook_entries = manifest.hooks
          # Fallback: if manifest has no hooks but source has hooks/*.rb, discover them
          if hook_entries.empty?
            discovered = Dir.glob(File.join(normalized_dir, "hooks", "*.rb")).map { |p| File.basename(p) }
            discovered.each do |bn|
              # Build minimal metadata so copy still happens (event unknown -> skipped by loader but copied for integrity)
              hook_entries[bn] = { sha256: "", event: "", on_error: "skip", priority: 100 }
            end
          end

          hook_entries.each do |basename, meta|
            next unless basename.is_a?(String) && !basename.empty?
            all_hooks_in_bundle << basename
            src = File.join(normalized_dir, "hooks", basename)
            next unless File.exist?(src)

            dest = File.join(hooks_target, basename)

            if @dry_run
              if File.exist?(dest) && !@force
                @results[basename] = { status: "would_skip" }
              else
                @results[basename] = { status: "would_install" }
              end
              next
            end

            # Local-edit detection for upgrade path (overwrite + warn)
            if @upgrade && existing_provenance && File.exist?(dest) && !@force
              prev_meta = existing_provenance[:hooks] ? (existing_provenance[:hooks][basename.to_sym] || existing_provenance[:hooks][basename]) : nil
              if prev_meta
                prev_sha = prev_meta[:sha256] || prev_meta["sha256"]
                if File.exist?(dest)
                  if !Provenance.recorded_sha(prev_sha).empty? && !Provenance.sha_matches?(dest, prev_sha)
                    @warnings << "Hook #{basename} was locally modified; overwriting"
                  end
                end
              end
            end

            FileUtils.mkdir_p(hooks_target)
            FileUtils.cp(src, dest)
            if @upgrade && existing_provenance
              @results[basename] = { status: "updated" }
            else
              @results[basename] = { status: "installed" }
            end
            hooks_files_for_provenance[basename] = dest
          end
        else
          # No manifest (non-strict): still copy any hooks/*.rb if present
          Dir.glob(File.join(normalized_dir, "hooks", "*.rb")).each do |src|
            basename = File.basename(src)
            all_hooks_in_bundle << basename
            dest = File.join(hooks_target, basename)
            if @dry_run
              @results[basename] = { status: "would_install" }
            else
              FileUtils.mkdir_p(hooks_target)
              FileUtils.cp(src, dest)
              @results[basename] = { status: "installed" }
              hooks_files_for_provenance[basename] = dest
            end
          end
        end

        # Prune stale hooks (removed from bundle) — reuse bases pruning via provenance but also remove files
        if @upgrade && existing_provenance && existing_provenance[:hooks] && !@dry_run
          existing_provenance[:hooks].keys.each do |old_key|
            old_key_str = old_key.to_s
            next if all_hooks_in_bundle.include?(old_key_str)
            old_dest = File.join(hooks_target, old_key_str)
            if File.exist?(old_dest) && !@force
              @warnings << "Bundle no longer includes hook #{old_key_str} but local file exists — removing"
            end
            FileUtils.rm_f(old_dest) if File.exist?(old_dest)
          end
        end

        # Verify hook checksums in strict mode (mirror .md block)
        if manifest && @strict
          all_hooks_in_bundle.each do |basename|
            next if @conflicts.key?(basename)
            expected = manifest.checksum_for_hook(basename)
            if expected
              dest = File.join(hooks_target, basename)
              next unless File.exist?(dest)
              actual = Digest::SHA256.hexdigest(File.read(dest))
              if actual != expected
                @warnings << "Checksum mismatch for hook #{basename}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
              end
            end
          end
        end

        # ── Guardrail rules: guardrails/*.yml into <bundle_dir>/guardrails/ ─
        # The bundle's set replaces what an earlier version installed.
        guardrails_target = provenance.guardrails_dir
        guardrail_files_for_provenance = {}
        incoming_rules = Dir.glob(File.join(normalized_dir, "guardrails", "*.yml")).sort
        if @dry_run
          incoming_rules.each { |src| @results["guardrails/#{File.basename(src)}"] = { status: "would_install" } }
        else
          # Same bytes as installed: reported as up to date, not "Installed".
          unchanged = incoming_rules.select do |src|
            dest = File.join(guardrails_target, File.basename(src))
            File.file?(dest) && FileUtils.identical?(src, dest)
          end
          FileUtils.rm_rf(guardrails_target)
          unless incoming_rules.empty?
            FileUtils.mkdir_p(guardrails_target)
            incoming_rules.each do |src|
              dest = File.join(guardrails_target, File.basename(src))
              FileUtils.cp(src, dest)
              @results["guardrails/#{File.basename(src)}"] =
                unchanged.include?(src) ? { status: "skipped", reason: "already up to date" } : { status: "installed" }
              guardrail_files_for_provenance[File.basename(src)] = dest
            end
          end
        end

        # ── Plugin: <file> into <bundle_dir>/plugin/ (docs/plugins.md) ────
        # Like the rules, the bundle's plugin replaces an earlier one.
        plugin_file_for_provenance = install_plugin(manifest, normalized_dir, provenance)

        # Files the previous version shipped and this one doesn't.
        if @upgrade && existing_provenance && existing_provenance[:files]
          prune_dropped_files(existing_provenance[:files], all_files_in_bundle, target_dir, target_scope, provenance)
        end

        # Verify checksums if we have a manifest (strict).
        if manifest && @strict
          all_files_in_bundle.each do |file_key|
            next if @conflicts.key?(file_key)
            status = @results[file_key] ? @results[file_key][:status].to_s : nil
            # skipped: not copied, so a local edit isn't a bad download.
            next if %w[kept kept_pruned fast_forward updated skipped].include?(status)
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

        warn_missing_needs(manifest) if manifest

        # Write provenance (only if we had a manifest and not dry_run). An
        # upgrade with conflicts writes it too: the new version, the plugin's
        # and hooks' new shas, and the old base for each conflicted file,
        # marked conflict (chi bundle status shows it). Skipping it left the
        # replaced plugin failing its sha check.
        if manifest && !@dry_run
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
              next unless File.exist?(target_path)

              # Skipped for a local edit: keep the installed base, so the
              # next upgrade still sees the edit (not a fast-forward over it).
              base_path = provenance.base_path(file_key)
              kept = existing_provenance && @results.dig(file_key, :reason) == "already exists" && File.exist?(base_path)
              provenance_files[file_key] = kept ? base_path : target_path
            end
          end
          # Build hooks metadata for provenance
          hooks_for_provenance = {}
          if manifest && manifest.hooks && !manifest.hooks.empty?
            hooks_for_provenance = manifest.hooks
          elsif hooks_files_for_provenance.any?
            hooks_files_for_provenance.each do |basename, path|
              next unless File.exist?(path)
              sha = Digest::SHA256.hexdigest(File.read(path))
              hooks_for_provenance[basename] = { "sha256" => "sha256:#{sha}", "event" => "", "on_error" => "skip", "priority" => 100 }
            end
          end
          Provenance.new(name: @name).write(
            files: provenance_files,
            scope: target_scope,
            version: manifest.version,
            source_path: @source,
            hooks: hooks_for_provenance,
            trust_level: manifest.respond_to?(:trust_level) ? manifest.trust_level : nil,
            source_commit: source_commit,
            hooks_files: hooks_files_for_provenance,
            guardrails_files: guardrail_files_for_provenance,
            plugin_file: plugin_file_for_provenance,
            requires_chi: manifest.requires_chi,
            needs: manifest.needs,
            conflicts: @conflicts.keys
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
        installed = @results.select { |_, r| r[:status].to_s == "installed" }.keys
        updated = @results.select { |_, r| r[:status].to_s == "updated" }.keys
        kept = @results.select { |_, r| %w[kept kept_pruned].include?(r[:status].to_s) }.keys
        skipped = @results.select { |_, r| %w[skipped noop would_skip].include?(r[:status].to_s) }.keys
        conflicts = @results.select { |_, r| r[:status].to_s == "conflict" }.keys
        would_install = @results.select { |_, r| r[:status].to_s == "would_install" }.keys
        fast_forward = @results.select { |_, r| r[:status].to_s == "fast_forward" }.keys
        removed = @results.select { |_, r| r[:status].to_s == "removed" }.keys
        would_remove = @results.select { |_, r| r[:status].to_s == "would_remove" }.keys

        lines << "Installed: #{installed.join(', ')}" unless installed.empty?
        lines << "Updated: #{updated.join(', ')}" unless updated.empty?
        lines << "Would install: #{would_install.join(', ')}" unless would_install.empty?
        lines << "Fast-forward: #{fast_forward.join(', ')}" unless fast_forward.empty?
        lines << "Removed (no longer in the bundle): #{removed.join(', ')}" unless removed.empty?
        lines << "Would remove (no longer in the bundle): #{would_remove.join(', ')}" unless would_remove.empty?
        lines << "Kept (local edits preserved): #{kept.join(', ')}" unless kept.empty?
        lines << "Skipped: #{skipped.join(', ')}" unless skipped.empty?
        lines << "Conflicts: #{conflicts.join(', ')}" unless conflicts.empty?
        lines.concat(@warnings) unless @warnings.empty?
        lines.concat(@placeholder_warnings) unless @placeholder_warnings.empty?
        lines << "#{@name} is already installed; `chi bundle upgrade #{@name}` updates it and keeps local edits" if @reinstall

        lines.any? ? lines.join("\n") : "No files to install."
      end

      private

      # A file the previous version installed that this one doesn't ship is
      # removed (with its index line) when it still matches what was
      # installed, or with --force; one the user edited is kept with a note.
      def prune_dropped_files(previous_files, bundle_files, target_dir, scope, provenance)
        previous_files.each do |old_key, meta|
          key = old_key.to_s
          next if bundle_files.include?(key)
          target = File.join(target_dir, key)
          next unless File.exist?(target)

          if @force || installed_unchanged?(target, meta, provenance.base_path(key))
            @results[key] = { status: @dry_run ? "would_remove" : "removed", reason: "no longer in the bundle" }
            next if @dry_run
            FileUtils.rm_f(target)
            remove_target_index(scope, key)
          else
            @results[key] = { status: "kept_pruned", reason: "local edits preserved" }
            @warnings << "Kept #{key}: no longer in the bundle but edited locally (use --force to remove)"
          end
        end
      end

      # Whether the file on disk is what the previous install wrote: its
      # recorded checksum, else the base snapshot. Unknown counts as edited.
      def installed_unchanged?(target, meta, base_path)
        recorded = meta.is_a?(Hash) ? meta[:checksum] || meta["checksum"] : nil
        return Provenance.sha_matches?(target, recorded) unless Provenance.recorded_sha(recorded).empty?
        File.exist?(base_path) && Provenance.file_sha(target) == Provenance.file_sha(base_path)
      end

      def remove_target_index(scope, file_key)
        IndexUpdater.remove_index(scope, file_key.delete_suffix(".md"))
        IndexUpdater.remove_index(scope, file_key) # legacy "name.md" line
      rescue StandardError
        # Best-effort, like update_target_index.
      end

      # One warning per need not found on this PATH (read-only, so dry-run
      # too). Installing goes ahead: needs are advisory.
      def warn_missing_needs(manifest)
        BundleNeeds.missing(manifest.needs).each do |need|
          hint = need[:hint] ? " (#{need[:hint]})" : ""
          @warnings << "needs #{need[:command]}: not found on PATH#{hint}; #{@dry_run ? "would install" : "installed"} anyway"
        end
      end

      # Copy the manifest's plugin file into the bundle's plugin/ dir,
      # warning when its sha256 differs from the declared one or this chi
      # doesn't meet requires_chi (the Engine then won't load it).
      # @return [String, nil] the installed file (nil: none, or a dry run)
      def install_plugin(manifest, source_dir, provenance)
        plugin = manifest&.plugin
        unless plugin
          FileUtils.rm_rf(provenance.plugin_dir) unless @dry_run
          return nil
        end

        src = File.join(source_dir, plugin[:file])
        raise InstallError, "the manifest names plugin #{plugin[:file]}, which the bundle doesn't have" unless File.file?(src)

        if (failure = Manifest.requires_chi_failure(manifest.requires_chi, Samagotchi::VERSION))
          @warnings << "Plugin #{plugin[:file]} won't load: #{failure}"
        end
        if @dry_run
          @results[plugin[:file]] = { status: "would_install" }
          return nil
        end

        FileUtils.rm_rf(provenance.plugin_dir)
        FileUtils.mkdir_p(provenance.plugin_dir)
        dest = File.join(provenance.plugin_dir, plugin[:file])
        FileUtils.cp(src, dest)
        @results[plugin[:file]] = { status: @upgrade && provenance.read ? "updated" : "installed" }
        expected = manifest.checksum_for_plugin
        actual = Digest::SHA256.hexdigest(File.binread(dest))
        if @strict && expected && actual != expected
          @warnings << "Checksum mismatch for plugin #{plugin[:file]}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
        end
        dest
      end

      def update_target_index(scope, file_path, file_key)
        byte_count = File.exist?(file_path) ? File.size(file_path) : 0
        entry_name = file_key.delete_suffix(".md")
        begin
          # Index lines use the entry name (as memory_write does); drop the
          # legacy "name.md" line older installs wrote.
          IndexUpdater.remove_index(scope, file_key) unless entry_name == file_key
          IndexUpdater.update_index(scope, entry_name, byte_count)
        rescue => _e
          # Silently skip index updates — they're best-effort.
        end
      end

      def resolve_target_dir(scope)
        MemoryPaths.scope_dir(scope) or raise InstallError, "invalid scope: #{scope}"
      end
    end
  end
end
