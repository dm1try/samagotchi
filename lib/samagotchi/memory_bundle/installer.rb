# frozen_string_literal: true

require "fileutils"
require "digest"
require_relative "../memory_paths"
require_relative "bundle_hook"
require_relative "provenance"
require_relative "manifest"
require_relative "source"
require_relative "placeholder"
require_relative "index_updater"
require_relative "merger"
require_relative "trash"
require_relative "../version"
require_relative "../bundle_needs"
require_relative "../model_overlay"

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
        @overlays = []
        @trash = Trash.new(name)
      end

      # Where an upgrade moved the files the bundle no longer ships (nil:
      # none moved).
      def trash_dir = @trash.dir

      # The normalized source dir, kept alive past #run when an upgrade has
      # conflicts (the agent step reads the incoming files); nil once cleaned.
      attr_reader :source_dir

      # Removes the normalized source dir an owned source (git/zip/tar) was
      # extracted to. #run defers this when it found conflicts, so the
      # conflict prompt and resolve_conflicts can still read the incoming
      # files; the caller runs it once the agent step is done. Idempotent.
      def cleanup_source!
        return unless @defer_cleanup && @normalized_dir

        SourceNormalizer.cleanup(@normalized_dir)
        @normalized_dir = nil
        @defer_cleanup = false
      end

      def run
        load_source
        manifest = @manifest
        normalized_dir = @bundle_dir
        source_commit = @source_commit
        @target_scope, @target_dir = resolve_target
        target_scope = @target_scope
        target_dir = @target_dir
        @file_descriptions = manifest&.file_descriptions || {}
        @provenance = provenance = Provenance.new(name: @name)
        @existing = existing_provenance = provenance.record
        # A plain install over an installed bundle: summary points at upgrade.
        @reinstall = existing_provenance && !@upgrade && !@force && !@dry_run
        install_memories
        all_files_in_bundle = @bundle_md
        owned = @owned

        install_hooks
        prune_dropped_hooks if @upgrade && existing_provenance && !@dry_run
        verify_hook_checksums if manifest && @strict
        all_hooks_in_bundle = @bundle_hooks
        hooks_files_for_provenance = @hook_files

        incoming_rules = Dir.glob(File.join(normalized_dir, "guardrails", "*.yml")).sort
        guardrail_files_for_provenance = install_guardrails(incoming_rules, provenance)
        # ── Plugin: <file> into <bundle_dir>/plugin/ (docs/plugins.md) ────
        # Like the rules, the bundle's plugin replaces an earlier one.
        plugin_file_for_provenance = install_plugin(manifest, normalized_dir, provenance)
        # ── Scripts: scripts/<file> into <bundle_dir>/scripts/ ────────────
        scripts_for_provenance = install_scripts(manifest, normalized_dir, provenance)
        warn_hooks_requires_chi(manifest, all_hooks_in_bundle)
        warn_rules_requires_chi(manifest, incoming_rules)

        # Files the previous version shipped and this one doesn't.
        if @upgrade && existing_provenance
          prune_dropped_files(existing_provenance.files, all_files_in_bundle, target_dir, target_scope, provenance)
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
            next unless expected

            actual = Digest::SHA256.hexdigest(File.read(target_path))
            if actual != expected
              @warnings << "Checksum mismatch for #{file_key}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
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
            owned.each do |file_key|
              target_path = File.join(target_dir, file_key)
              next unless File.exist?(target_path)

              status = @results[file_key] ? @results[file_key][:status].to_s : nil
              if %w[kept noop conflict kept_pruned].include?(status)
                # Keep old base snapshot — do not overwrite with edited current
                # Use base snapshot as source if it exists to preserve old checksum
                base_path = provenance.base_path(file_key)
                provenance_files[file_key] = if File.exist?(base_path)
                                               # Keep existing provenance entry by re-using base content
                                               # We still need to include it to prevent pruning, but with base content
                                               base_path
                                             else
                                               target_path
                                             end
              else
                # installed, updated, skipped — use current target (which is incoming for updated)
                provenance_files[file_key] = target_path
              end
            end
            # Handle pruned but kept files (bundle removed file but local kept)
            existing_provenance.files.each_key do |old_key_str|
              next if all_files_in_bundle.include?(old_key_str)

              # If it was kept_pruned, include it with base content to prevent pruning
              next unless @results[old_key_str] && @results[old_key_str][:status].to_s == "kept_pruned"

              base_path = provenance.base_path(old_key_str)
              target_path = File.join(target_dir, old_key_str)
              # Use base if exists to keep old checksum, else target
              src = File.exist?(base_path) ? base_path : target_path
              provenance_files[old_key_str] = src if File.exist?(src)
            end
          else
            owned.each do |file_key|
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

              hooks_for_provenance[basename] = BundleHook.of_file(path)
            end
          end
          Provenance.new(name: @name).write(
            files: provenance_files,
            scope: target_scope,
            version: manifest.version,
            source_path: @source,
            hooks: hooks_for_provenance,
            trust_level: manifest.trust_level,
            source_commit: source_commit,
            hooks_files: hooks_files_for_provenance,
            guardrails_files: guardrail_files_for_provenance,
            plugin_file: plugin_file_for_provenance,
            requires_chi: manifest.requires_chi,
            needs: manifest.needs,
            conflicts: @conflicts.keys,
            scripts_files: scripts_for_provenance,
            context_providers: manifest.context_providers,
            file_descriptions: manifest.file_descriptions
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
        # An owned source (git/zip/tar) is cleaned up here, unless an upgrade
        # kept conflicts: the agent step still needs the incoming files, so
        # the caller runs #cleanup_source! when it is done.
        if @source_owned
          if @conflicts.any? && !@dry_run
            @defer_cleanup = true
          else
            SourceNormalizer.cleanup(@normalized_dir)
            @normalized_dir = nil
          end
        end
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

        lines << "Installed: #{installed.join(", ")}" unless installed.empty?
        lines << "Updated: #{updated.join(", ")}" unless updated.empty?
        lines << "Would install: #{would_install.join(", ")}" unless would_install.empty?
        lines << "Fast-forward: #{fast_forward.join(", ")}" unless fast_forward.empty?
        lines << "Removed (no longer in the bundle): #{removed.join(", ")}#{" (moved to #{trash_dir})" if trash_dir}" unless removed.empty?
        lines << "Would remove (no longer in the bundle): #{would_remove.join(", ")}" unless would_remove.empty?
        lines << "Kept (local edits preserved): #{kept.join(", ")}" unless kept.empty?
        lines << "Skipped: #{skipped.join(", ")}" unless skipped.empty?
        lines << "Conflicts: #{conflicts.join(", ")}" unless conflicts.empty?
        lines.concat(@warnings) unless @warnings.empty?
        lines.concat(@placeholder_warnings) unless @placeholder_warnings.empty?
        lines << "#{@name} is already installed; `chi bundle upgrade #{@name}` updates it and keeps local edits" if @reinstall

        lines.any? ? lines.join("\n") : "No files to install."
      end

      private

      # The source normalized to a dir (@bundle_dir; an owned one, extracted
      # from git/zip/tar, is cleaned up after #run) and its manifest.yml
      # (@manifest, nil when it has none and the install isn't strict).
      def load_source
        @bundle_dir, @source_owned, @source_commit = SourceNormalizer.normalize(@source)
        @normalized_dir = @bundle_dir
        @manifest = Manifest.read(dir: @bundle_dir)
      rescue SourceNormalizer::UnknownSourceError => e
        raise InstallError, "Source normalization failed: #{e.message}"
      rescue Manifest::ValidationError => e
        raise InstallError, e.message if @strict

        @warnings << "No manifest found — proceeding without strict manifest validation"
      end

      # The scope the files go to (the CLI's wins over the manifest's) and
      # its dir, created.
      # @return [Array(String, String)] scope, dir
      def resolve_target
        cli_scope = @scope.to_s.strip.empty? ? nil : @scope
        scope = cli_scope || @manifest&.scope || "system"
        dir = MemoryPaths.scope_dir(scope) or raise InstallError, "invalid scope: #{scope}"
        FileUtils.mkdir_p(dir)
        [scope, dir]
      end

      # Copies the bundle's *.md files into the target dir and refreshes
      # their index lines: an upgrade merges (merge_memory), a dry run only
      # classifies (preview_memory), a plain install writes the new ones.
      # Sets @bundle_md (every file the bundle ships) and @owned: the bundle
      # owns (records, upgrades, removes) only the files it wrote, these
      # from an earlier install and the ones written now. A same-name file
      # that was already there is the user's: skipped and never recorded.
      def install_memories
        owned_before = @existing ? @existing.files.keys : []
        @bundle_md = []
        @owned = []
        Dir.glob(File.join(@bundle_dir, "*.md")).each do |file_path|
          file_key = File.basename(file_path)
          @bundle_md << file_key
          note_overlay(file_key, @target_dir)
          target_path = File.join(@target_dir, file_key)
          merging = @upgrade && @existing && !@force

          if merging && File.exist?(target_path) && !owned_before.include?(file_key)
            # Not the bundle's (the user's, or another bundle's): no merge.
            skip_existing(file_key, file_path, target_path, @target_scope)
          elsif merging && !@dry_run
            @owned << file_key
            merge_memory(file_key, file_path, target_path)
          elsif @dry_run
            preview_memory(file_key, file_path, target_path)
          elsif File.exist?(target_path) && !@force
            # A re-install keeps what an earlier install wrote.
            @owned << file_key if owned_before.include?(file_key)
            skip_existing(file_key, file_path, target_path, @target_scope, owned: owned_before.include?(file_key))
          else
            FileUtils.cp(file_path, target_path)
            @owned << file_key
            @results[file_key] = { status: "installed" }
            update_target_index(@target_scope, target_path, file_key)
          end
        end
      end

      # An upgrade's 3-way merge of one file (Merger.classify against the
      # base the last install recorded); a conflict leaves the local file
      # and is recorded in @conflicts for the agent step.
      def merge_memory(file_key, file_path, target_path)
        base_path = @provenance.base_path(file_key)
        case Merger.classify(base_path: base_path, current_path: target_path, incoming_path: file_path)
        when :install
          FileUtils.cp(file_path, target_path)
          @results[file_key] = { status: "installed" }
        when :fast_forward
          FileUtils.cp(file_path, target_path)
          @results[file_key] = { status: "updated", reason: "auto-merged (not edited)" }
        when :keep
          @results[file_key] = { status: "kept", reason: "bundle unchanged, local edits preserved" }
        when :noop
          @results[file_key] = { status: "skipped", reason: "already up to date" }
        when :conflict
          @results[file_key] = { status: "conflict", reason: "local edits conflict with bundle update" }
          @conflicts[file_key] = { base: base_path, current: target_path, incoming: file_path }
          @warnings << "Conflict in #{file_key}: local edits conflict with bundle update (use --force to overwrite or resolve interactively)"
        end
        update_target_index(@target_scope, target_path, file_key)
      end

      # A dry run's verdict for one file, nothing written: an upgrade
      # classifies as merge_memory would (its status is the classification).
      def preview_memory(file_key, file_path, target_path)
        unless File.exist?(target_path) && !@force
          @results[file_key] = { status: "would_install" }
          return
        end

        if @upgrade && @existing
          base_path = @provenance.base_path(file_key)
          classification = Merger.classify(base_path: base_path, current_path: target_path, incoming_path: file_path)
          @results[file_key] = { status: classification.to_s }
          @conflicts[file_key] = { base: base_path, current: target_path, incoming: file_path } if classification == :conflict
        elsif FileUtils.identical?(file_path, target_path)
          @results[file_key] = { status: "skipped", reason: "already up to date" }
        else
          @results[file_key] = { status: "would_skip" }
        end
      end

      # Copies the bundle's hooks/*.rb into <bundle_dir>/hooks/: the ones
      # its manifest lists, else (no hooks: in it) every hooks/*.rb, which is
      # then added to manifest.hooks with no event (the loader skips it, the
      # record keeps it). Without a manifest every hooks/*.rb is copied.
      # Sets @bundle_hooks (every hook the bundle ships) and @hook_files
      # (basename => installed path, for the record).
      def install_hooks
        @bundle_hooks = []
        @hook_files = {}
        return install_unlisted_hooks unless @manifest

        hook_entries = @manifest.hooks
        if hook_entries.empty?
          Dir.glob(File.join(@bundle_dir, "hooks", "*.rb")).each { |p| hook_entries[File.basename(p)] = BundleHook.new }
        end
        hook_entries.each_key do |basename|
          next unless basename.is_a?(String) && !basename.empty?

          @bundle_hooks << basename
          src = File.join(@bundle_dir, "hooks", basename)
          install_hook(basename, src) if File.exist?(src)
        end
      end

      # One listed hook; an upgrade overwrites a local edit with a warning.
      def install_hook(basename, src)
        dest = File.join(@provenance.hooks_dir, basename)
        if @dry_run
          @results[basename] = { status: File.exist?(dest) && !@force ? "would_skip" : "would_install" }
          return
        end

        prev_sha = @existing&.hooks&.dig(basename)&.sha256
        if @upgrade && File.exist?(dest) && !@force && !Provenance.recorded_sha(prev_sha).empty? && !Provenance.sha_matches?(dest, prev_sha)
          @warnings << "Hook #{basename} was locally modified; overwriting"
        end

        FileUtils.mkdir_p(@provenance.hooks_dir)
        unchanged = File.exist?(dest) && FileUtils.identical?(src, dest)
        FileUtils.cp(src, dest)
        @results[basename] = if unchanged
                               { status: "skipped", reason: "already up to date" }
                             elsif @upgrade && @existing
                               { status: "updated" }
                             else
                               { status: "installed" }
                             end
        @hook_files[basename] = dest
      end

      # No manifest (a non-strict install): every hooks/*.rb is copied.
      def install_unlisted_hooks
        Dir.glob(File.join(@bundle_dir, "hooks", "*.rb")).each do |src|
          basename = File.basename(src)
          @bundle_hooks << basename
          if @dry_run
            @results[basename] = { status: "would_install" }
          else
            FileUtils.mkdir_p(@provenance.hooks_dir)
            dest = File.join(@provenance.hooks_dir, basename)
            FileUtils.cp(src, dest)
            @results[basename] = { status: "installed" }
            @hook_files[basename] = dest
          end
        end
      end

      # An upgrade removes the hooks the previous version shipped and this
      # one doesn't (a local file too, with a warning).
      def prune_dropped_hooks
        @existing.hooks.each_key do |old_key_str|
          next if @bundle_hooks.include?(old_key_str)

          old_dest = File.join(@provenance.hooks_dir, old_key_str)
          if File.exist?(old_dest) && !@force
            @warnings << "Bundle no longer includes hook #{old_key_str} but local file exists — removing"
          end
          FileUtils.rm_f(old_dest)
        end
      end

      # Strict mode: an installed hook whose sha256 differs from the one its
      # manifest declares warns (as verify_memory_checksums does).
      def verify_hook_checksums
        @bundle_hooks.each do |basename|
          next if @conflicts.key?(basename)

          expected = @manifest.checksum_for_hook(basename)
          next unless expected

          dest = File.join(@provenance.hooks_dir, basename)
          next unless File.exist?(dest)

          actual = Digest::SHA256.hexdigest(File.read(dest))
          if actual != expected
            @warnings << "Checksum mismatch for hook #{basename}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
          end
        end
      end

      # A file already in the target dir that the install doesn't write: the
      # same bytes are "already up to date", others are skipped with a
      # --force hint (a dry run: would_skip). Its index line is refreshed
      # (not on a dry run).
      def skip_existing(file_key, file_path, target_path, scope, owned: false)
        if FileUtils.identical?(file_path, target_path)
          @results[file_key] = { status: "skipped", reason: "already up to date" }
        elsif @dry_run
          @results[file_key] = { status: "would_skip" }
          return
        else
          @results[file_key] = { status: "skipped", reason: "already exists" }
          @warnings << "Skipped #{file_key} (already exists; use --force to overwrite)"
        end
        update_target_index(scope, target_path, file_key, owned: owned) unless @dry_run
      end

      # A file the previous version installed that this one doesn't ship is
      # moved to the trash (with its index line removed) when it still
      # matches what was installed, or with --force; one the user edited is
      # kept with a note.
      def prune_dropped_files(previous_files, bundle_files, target_dir, scope, provenance)
        previous_files.each do |key, meta|
          next if bundle_files.include?(key)

          target = File.join(target_dir, key)
          next unless File.exist?(target)

          others = Provenance.claimants(key, scope: scope, except: @name)
          if others.any?
            @results[key] = { status: "kept_shared", reason: "bundle #{others.join(", ")} has it too" }
            @warnings << "Kept #{key}: no longer in the bundle, but bundle #{others.join(", ")} has it too"
          elsif @force || installed_unchanged?(target, meta, provenance.base_path(key))
            @results[key] = { status: @dry_run ? "would_remove" : "removed", reason: "no longer in the bundle" }
            next if @dry_run

            @trash.move(target)
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
        recorded = meta[:checksum]
        return Provenance.sha_matches?(target, recorded) unless Provenance.recorded_sha(recorded).empty?

        File.exist?(base_path) && Provenance.file_sha(target) == Provenance.file_sha(base_path)
      end

      # Not fatal, like update_target_index: a warning says so.
      def remove_target_index(scope, file_key)
        IndexUpdater.remove_index(scope, file_key.delete_suffix(".md"))
        IndexUpdater.remove_index(scope, file_key) # legacy "name.md" line
      rescue StandardError => e
        @warnings << "index.md: line for #{file_key.delete_suffix(".md")} not removed (#{e.message})"
      end

      # One warning per need not found on this PATH (read-only, so dry-run
      # too). Installing goes ahead: needs are advisory.
      def warn_missing_needs(manifest)
        BundleNeeds.missing(manifest.needs).each do |need|
          hint = need[:hint] ? " (#{need[:hint]})" : ""
          @warnings << "needs #{need[:command]}: not found on PATH#{hint}; #{@dry_run ? "would install" : "installed"} anyway"
        end
      end

      # The hook loader skips every hook of a bundle whose requires_chi this
      # chi doesn't meet (Hooks::BundleLoader); say so at install, as
      # install_plugin does for the plugin.
      def warn_hooks_requires_chi(manifest, hook_files)
        return if manifest.nil? || hook_files.empty?

        if (failure = Manifest.requires_chi_failure(manifest.requires_chi, Samagotchi::VERSION))
          @warnings << "Bundle #{@name}: its hooks won't load: #{failure}"
        end
      end

      # GuardrailWiring#bundle_rules doesn't read the rules of a bundle whose
      # requires_chi this chi doesn't meet, and a session that never loaded
      # them records a required load failure (the gate refuses guarded calls
      # until chi is updated): say so at install, as the hooks warning does.
      def warn_rules_requires_chi(manifest, rule_files)
        return if manifest.nil? || rule_files.empty?

        if (failure = Manifest.requires_chi_failure(manifest.requires_chi, Samagotchi::VERSION))
          @warnings << "Bundle #{@name}: its guardrail rules won't load: #{failure}; until chi is updated " \
                       "(chi update), guarded tool calls are refused"
        end
      end

      # The bundle's guardrails/*.yml into <bundle_dir>/guardrails/: the
      # set replaces what an earlier version installed. Same bytes as
      # installed are reported up to date, not "Installed".
      # @return [Hash{String => String}] basename => installed path ({} on a dry run)
      def install_guardrails(incoming_rules, provenance)
        if @dry_run
          incoming_rules.each { |src| @results["guardrails/#{File.basename(src)}"] = { status: "would_install" } }
          return {}
        end

        target = provenance.guardrails_dir
        unchanged = incoming_rules.select do |src|
          dest = File.join(target, File.basename(src))
          File.file?(dest) && FileUtils.identical?(src, dest)
        end
        FileUtils.rm_rf(target)
        return {} if incoming_rules.empty?

        FileUtils.mkdir_p(target)
        incoming_rules.to_h do |src|
          dest = File.join(target, File.basename(src))
          FileUtils.cp(src, dest)
          @results["guardrails/#{File.basename(src)}"] =
            unchanged.include?(src) ? { status: "skipped", reason: "already up to date" } : { status: "installed" }
          [File.basename(src), dest]
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

        dest = File.join(provenance.plugin_dir, plugin[:file])
        unchanged = File.file?(dest) && FileUtils.identical?(src, dest)
        FileUtils.rm_rf(provenance.plugin_dir)
        FileUtils.mkdir_p(provenance.plugin_dir)
        FileUtils.cp(src, dest)
        @results[plugin[:file]] = if unchanged
                                    { status: "skipped", reason: "already up to date" }
                                  elsif @upgrade && provenance.installed?
                                    { status: "updated" }
                                  else
                                    { status: "installed" }
                                  end
        expected = manifest.checksum_for_plugin
        actual = Digest::SHA256.hexdigest(File.binread(dest))
        if @strict && expected && actual != expected
          @warnings << "Checksum mismatch for plugin #{plugin[:file]}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
        end
        dest
      end

      # The manifest's scripts, copied into <bundle_dir>/scripts/ (the
      # folder replaced: a script the new version dropped goes). A declared
      # sha256 that differs warns, as a plugin's does.
      # @return [Hash{String => String}] file name => installed path
      def install_scripts(manifest, source_dir, provenance)
        scripts = manifest&.scripts || {}
        scripts.each_key do |file|
          next if File.file?(File.join(source_dir, "scripts", file))

          raise InstallError, "the manifest names scripts/#{file}, which the bundle doesn't have"
        end
        return {} if @dry_run

        unchanged = scripts.keys.select do |file|
          dest = File.join(provenance.scripts_dir, file)
          File.file?(dest) && FileUtils.identical?(File.join(source_dir, "scripts", file), dest)
        end
        FileUtils.rm_rf(provenance.scripts_dir)
        return {} if scripts.empty?

        FileUtils.mkdir_p(provenance.scripts_dir)
        scripts.to_h do |file, declared|
          dest = File.join(provenance.scripts_dir, file)
          FileUtils.cp(File.join(source_dir, "scripts", file), dest)
          @results["scripts/#{file}"] = if unchanged.include?(file) then { status: "skipped", reason: "already up to date" }
                                        elsif @upgrade && provenance.installed? then { status: "updated" }
                                        else { status: "installed" }
                                        end
          FileUtils.chmod(0o755, dest)
          actual = Digest::SHA256.hexdigest(File.binread(dest))
          expected = declared.to_s.delete_prefix("sha256:")
          if @strict && !expected.empty? && actual != expected
            @warnings << "Checksum mismatch for script #{file}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
          end
          [file, dest]
        end
      end

      # A model overlay (<name>.<key>.md, docs/memory.md) loads only with
      # its base, under the matching model: it gets no index line (every
      # model would see it as a memory of its own). Its base is looked for
      # in the bundle dir, not the target: Dir.glob sorts tips.<key>.md
      # before tips.md, so on a fresh install the base isn't copied yet.
      # An overlay-looking name with no base anywhere is an overlay too,
      # with a warning (a dry run warns as well).
      def note_overlay(file_key, target_dir)
        @bundle_files ||= Dir.glob(File.join(@bundle_dir, "*.md")).map { |f| File.basename(f) }
        return unless ModelOverlay.bundle_overlay?(file_key, bundle_files: @bundle_files, target_dir: target_dir)

        @overlays << file_key
        base = ModelOverlay.base_file_for(file_key)
        return if @bundle_files.include?(base)

        @warnings << if File.file?(File.join(target_dir, base))
                       "#{file_key} is taken as a model overlay of your #{base}, which the bundle doesn't ship; " \
                         "it gets no index line"
                     else
                       "#{file_key} is a model overlay with no #{base}; it loads only once #{base} exists"
                     end
      end

      # +owned+: the bundle wrote (owns) the file, so its line says
      # "· from <bundle>"; a skipped file's line keeps whatever it had.
      # An overlay gets none: a stale one (an earlier install's) is removed.
      def update_target_index(scope, file_path, file_key, owned: true)
        if @overlays.include?(file_key)
          remove_target_index(scope, file_key) if owned
          return
        end

        byte_count = File.exist?(file_path) ? File.size(file_path) : 0
        entry_name = file_key.delete_suffix(".md")
        begin
          # Index lines use the entry name (as memory_write does); drop the
          # legacy "name.md" line older installs wrote.
          IndexUpdater.remove_index(scope, file_key) unless entry_name == file_key
          # A manifest's description: for the file; nil keeps the line's.
          description = owned ? @file_descriptions&.[](file_key) : nil
          IndexUpdater.update_index(scope, entry_name, byte_count, description, source: owned ? @name : nil)
        rescue StandardError => e
          # Not fatal (the file is in place): a warning says so.
          @warnings << "index.md: line for #{entry_name} not updated (#{e.message})"
        end
      end
    end
  end
end
