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
require_relative "trash"
require_relative "asset_installer"
require_relative "../bundle_needs"
require_relative "../model_overlay"

module Samagotchi
  module MemoryBundle
    # Installs a bundle into a scoped memories directory.
    #
    # Flow (#run):
    #   1. Normalize source → directory, read manifest.yml (load_source)
    #   2. Copy .md files to the target scope dir and update index.md
    #      (install_memories: plain, dry run, or an upgrade's 3-way merge)
    #   3. Hooks, guardrail rules, plugin, scripts into .bundles/<name>/
    #      (AssetInstaller)
    #   4. An upgrade prunes the files the bundle dropped
    #   5. Verify checksums (strict mode), warn about missing needs
    #   6. Write provenance (.bundles/<name>/manifest.json, write_provenance)
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

      # The normalized source dir. An owned one (a git/zip/tar extract) is
      # removed after #run, or kept until #cleanup_source! when an upgrade
      # has conflicts (the agent step reads the incoming files); nil once
      # cleaned.
      attr_reader :source_dir

      # Removes the normalized source dir an owned source (git/zip/tar) was
      # extracted to. #run defers this when it found conflicts, so the
      # conflict prompt and resolve_conflicts can still read the incoming
      # files; the caller runs it once the agent step is done. Idempotent.
      def cleanup_source!
        return unless @defer_cleanup && @source_dir

        SourceNormalizer.cleanup(@source_dir)
        @source_dir = nil
        @defer_cleanup = false
      end

      def run
        load_source
        @target_scope, @target_dir = resolve_target
        @file_descriptions = @manifest&.file_descriptions || {}
        @provenance = Provenance.new(name: @name)
        @existing = @provenance.record
        # A plain install over an installed bundle: summary points at upgrade.
        @reinstall = @existing && !@upgrade && !@force && !@dry_run
        install_memories

        installed = AssetInstaller.new(
          name: @name, source_dir: @bundle_dir, manifest: @manifest, provenance: @provenance, existing: @existing,
          results: @results, warnings: @warnings, conflicts: @conflicts,
          force: @force, strict: @strict, upgrade: @upgrade, dry_run: @dry_run
        ).run

        # Files the previous version shipped and this one doesn't.
        prune_dropped_files(@existing.files, @bundle_md, @target_dir, @target_scope, @provenance) if @upgrade && @existing
        verify_memory_checksums if @manifest && @strict
        warn_missing_needs(@manifest) if @manifest
        if @manifest && !@dry_run
          write_provenance(installed)
        end
        detect_placeholders

        [@bundle_dir, @manifest]
      ensure
        # An owned source (git/zip/tar) is cleaned up here, unless an upgrade
        # kept conflicts: the agent step still needs the incoming files, so
        # the caller runs #cleanup_source! when it is done.
        if @source_owned
          if @conflicts.any? && !@dry_run
            @defer_cleanup = true
          else
            SourceNormalizer.cleanup(@source_dir)
            @source_dir = nil
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
        @source_dir = @bundle_dir
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

      # Strict mode: a memory written from the bundle whose sha256 differs
      # from its manifest's warns. One that wasn't copied (kept, skipped:
      # a local edit isn't a bad download) or was merged isn't checked.
      def verify_memory_checksums
        @bundle_md.each do |file_key|
          next if @conflicts.key?(file_key)

          status = @results[file_key] ? @results[file_key][:status].to_s : nil
          next if %w[kept kept_pruned fast_forward updated skipped].include?(status)

          target_path = File.join(@target_dir, file_key)
          next unless File.exist?(target_path)

          expected = @manifest.checksum_for(file_key)
          next unless expected

          actual = Digest::SHA256.hexdigest(File.read(target_path))
          if actual != expected
            @warnings << "Checksum mismatch for #{file_key}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
          end
        end
      end

      # One line per memory with {{placeholders}} left to fill in.
      def detect_placeholders
        @bundle_md.each do |file_key|
          file_path = File.join(@target_dir, file_key)
          next unless File.exist?(file_path)

          names = Placeholder.detect_in_file(file_path)
          @placeholder_warnings << "#{file_key}: {{#{names.join("}}, {{")}}}" if names.any?
        end
      end

      # The install's record (Provenance#write), only with a manifest and
      # not on a dry run. An upgrade with conflicts writes it too: the new
      # version, the plugin's and hooks' new shas, and the old base for each
      # conflicted file, marked conflict (chi bundle status shows it).
      # Skipping it left the replaced plugin failing its sha check.
      # @param installed [AssetInstaller::Installed]
      def write_provenance(installed)
        @provenance.write(
          files: @upgrade && @existing ? upgrade_provenance_files : install_provenance_files,
          scope: @target_scope,
          version: @manifest.version,
          source_path: @source,
          # AssetInstaller added the discovered hooks/*.rb to manifest.hooks.
          hooks: @manifest.hooks,
          trust_level: @manifest.trust_level,
          source_commit: @source_commit,
          hooks_files: installed.hook_files,
          guardrails_files: installed.guardrail_files,
          plugin_file: installed.plugin_file,
          requires_chi: @manifest.requires_chi,
          needs: @manifest.needs,
          conflicts: @conflicts.keys,
          scripts_files: installed.script_files,
          context_providers: @manifest.context_providers,
          file_descriptions: @manifest.file_descriptions
        )
      end

      # file key => the file whose content becomes its base. A file the
      # upgrade left as the user has it (kept, noop, conflict, kept_pruned)
      # keeps its old base, so the next upgrade still sees the local edit;
      # the rest (installed, updated, skipped) take what is on disk now. A
      # file the bundle dropped but the user kept stays recorded too.
      def upgrade_provenance_files
        files = {}
        @owned.each do |file_key|
          target_path = File.join(@target_dir, file_key)
          next unless File.exist?(target_path)

          status = @results[file_key] ? @results[file_key][:status].to_s : nil
          base_path = @provenance.base_path(file_key)
          files[file_key] = %w[kept noop conflict kept_pruned].include?(status) && File.exist?(base_path) ? base_path : target_path
        end
        @existing.files.each_key do |old_key_str|
          next if @bundle_md.include?(old_key_str)
          next unless @results[old_key_str] && @results[old_key_str][:status].to_s == "kept_pruned"

          base_path = @provenance.base_path(old_key_str)
          src = File.exist?(base_path) ? base_path : File.join(@target_dir, old_key_str)
          files[old_key_str] = src if File.exist?(src)
        end
        files
      end

      # file key => its base's content source for a plain install. Skipped
      # for a local edit: keep the installed base, so the next upgrade still
      # sees the edit (not a fast-forward over it).
      def install_provenance_files
        @owned.each_with_object({}) do |file_key, files|
          target_path = File.join(@target_dir, file_key)
          next unless File.exist?(target_path)

          base_path = @provenance.base_path(file_key)
          kept = @existing && @results.dig(file_key, :reason) == "already exists" && File.exist?(base_path)
          files[file_key] = kept ? base_path : target_path
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
