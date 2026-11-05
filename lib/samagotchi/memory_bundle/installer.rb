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
require_relative "memory_files"
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

      # Each file this run left behind (FileStanding::Behind).
      attr_reader :behind

      # prepared: the source already normalized (a PreparedSource, which the
      # Installer then owns and cleans up as its own); nil normalizes source.
      # shipped_dir: the bundles this chi ships (a bundle of their names
      # installs from a dir in it only, unless force); ShippedUpdate,
      # Profile and SystemBundle pass the one they install from.
      def initialize(source:, name:, scope: nil, force: false, strict: true, upgrade: false, dry_run: false, prepared: nil,
                     shipped_dir: SourceNormalizer::SHIPPED_DIR, dev: false)
        @source = source
        @shipped_dir = shipped_dir
        @prepared = prepared
        @name = name
        @scope = scope&.to_s&.strip&.downcase || ""
        @force = force
        @strict = strict
        @upgrade = upgrade
        @dry_run = dry_run
        @dev = dev
        @results = {}
        @warnings = []
        @placeholder_warnings = []
        @conflicts = {}
        @behind = []
        @replaced = []
        @outcomes = {}
        @overlays = []
        @trash = Trash.new(name)
      end

      # [recorded source, this source] when an upgrade switches the bundle's
      # source (Installer#check_source), else nil.
      attr_reader :source_change

      # Where this install moved the files the bundle no longer ships and
      # copied the ones it overwrote (nil: none).
      def trash_dir = @trash.dir

      # What it copied to the trash before overwriting, said once (nil: nothing).
      def trash_copy_line = @trash.copy_line

      # The files this run merged, the bundle's changes joined to the user's.
      def merged_files = @results.select { |_, r| r[:status] == "merged" }.keys

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
        check_source
        # A plain install over an installed bundle: summary points at upgrade.
        @reinstall = @existing && !@upgrade && !@force && !@dry_run
        installed = replace_files
        verify_memory_checksums if @manifest && @strict
        warn_missing_needs(@manifest) if @manifest
        if @manifest && !@dry_run
          write_provenance(installed)
        end
        detect_placeholders

        [@bundle_dir, @manifest]
      ensure
        note_merges
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
        lines << "Source changes: #{@source_change.join(" → ")}" if @source_change
        installed = @results.select { |_, r| r[:status].to_s == "installed" }.keys
        updated = @results.select { |_, r| r[:status].to_s == "updated" }.keys
        merged = merged_files
        would_merge = @results.select { |_, r| r[:status].to_s == "would_merge" }.keys
        kept = @results.select { |_, r| %w[kept keep kept_pruned].include?(r[:status].to_s) }.keys
        skipped = @results.select { |_, r| %w[skipped noop would_skip].include?(r[:status].to_s) }.keys
        would_install = @results.select { |_, r| r[:status].to_s == "would_install" }.keys
        fast_forward = @results.select { |_, r| r[:status].to_s == "fast_forward" }.keys
        removed = @results.select { |_, r| r[:status].to_s == "removed" }.keys
        would_remove = @results.select { |_, r| r[:status].to_s == "would_remove" }.keys

        lines << "Installed: #{installed.join(", ")}" unless installed.empty?
        lines << "Updated: #{updated.join(", ")}" unless updated.empty?
        lines << "Would install: #{would_install.join(", ")}" unless would_install.empty?
        lines << "Fast-forward: #{fast_forward.join(", ")}" unless fast_forward.empty?
        lines << FileStanding.merged_line(merged, @manifest&.version) unless merged.empty?
        lines << FileStanding.merged_line(would_merge, @manifest&.version, dry_run: true) unless would_merge.empty?
        lines << "Removed (no longer in the bundle): #{removed.join(", ")}#{" (moved to #{trash_dir})" if trash_dir}" unless removed.empty?
        lines << "Would remove (no longer in the bundle): #{would_remove.join(", ")}" unless would_remove.empty?
        lines << "Kept (local edits preserved): #{kept.join(", ")}" unless kept.empty?
        lines << "Skipped: #{skipped.join(", ")}" unless skipped.empty?
        lines << trash_copy_line if trash_copy_line
        lines.concat(@warnings) unless @warnings.empty?
        lines.concat(@placeholder_warnings) unless @placeholder_warnings.empty?
        lines << "#{@name} is already installed; `chi bundle upgrade #{@name}` updates it and keeps local edits" if @reinstall

        lines.any? ? lines.join("\n") : "No files to install."
      end

      private

      # The steps that replace files: memories, the bundle's own folder, then
      # the files it dropped. The record isn't written yet, so a failed run is
      # retried as the same upgrade.
      # @return [AssetInstaller::Installed]
      # @raise [InstallError] a file system error (a file it can't read, a
      #   .trash it can't write)
      def replace_files
        install_memories

        installed = AssetInstaller.new(
          name: @name, source_dir: @bundle_dir, manifest: @manifest, provenance: @provenance, existing: @existing,
          results: @results, warnings: @warnings, conflicts: @conflicts, trash: @trash,
          force: @force, strict: @strict, upgrade: @upgrade, dry_run: @dry_run, dev: @dev
        ).run

        # Files the previous version shipped and this one doesn't.
        prune_dropped_files(@existing.files, @bundle_md, @target_dir, @target_scope, @provenance) if @upgrade && @existing
        installed
      rescue SystemCallError => e
        raise InstallError, Trash.failure_message(e)
      end

      # Who may install under this name (a manifest can take any name: a
      # repo calling itself guardrails). Sources compare by SourceIdentity
      # (a shipped dir by name, in any gem or checkout; a git URL without
      # #ref; a path resolved); one it can't place (an older record's
      # relative path) never refuses.
      #   - a name chi ships comes from a shipped dir only, unless --force
      #     (install and upgrade): the plugin and hooks it replaces are chi's;
      #   - a plain install over a bundle from another source is refused,
      #     --force too (that overwrites files, it doesn't switch sources):
      #     it would delete the plugin and hooks and rewrite the record;
      #   - an upgrade may switch sources (a URL and a local copy of it are
      #     one bundle, an archive's file name has its version), and
      #     #source_change says so (the summary's first line).
      def check_source
        refuse_case_twin
        refuse_shipped_name
        refuse_dev_mismatch
        now = incoming_identity
        return if now.nil?

        was = @existing && SourceIdentity.of(@existing.source)
        if @dev && @existing&.dev && was != now
          raise InstallError, "#{@name} is a dev install of #{@existing.source}; uninstall it before installing from #{@source}"
        end
        return if was.nil? || was == now
        return @source_change = [@existing.source, @source.to_s] if @upgrade

        raise InstallError, "#{@name} is installed from #{@existing.source}; `chi bundle upgrade #{@source}` " \
                            "switches its source, or `chi bundle uninstall #{@name}` first"
      end

      # A name that differs from an installed bundle's only in case is that
      # bundle's dir on a case-insensitive file system (macOS): BTW would
      # replace btw. Refused, --force too.
      def refuse_case_twin
        twin, = Provenance.each_installed.find { |name, _| name != @name && name.casecmp?(@name) }
        raise InstallError, "#{@name} differs only in case from the installed #{twin}" if twin
      end

      # A dev install (--dev, linked to its source) and a normal one don't
      # replace each other: neither an upgrade nor a plain install over a
      # dev bundle, nor --dev over a normal one.
      def refuse_dev_mismatch
        return if @existing.nil? || @existing.dev == @dev

        if @existing.dev
          raise InstallError, "#{@name} is a dev install of #{@existing.source}: it follows its source already " \
                              "(to leave dev mode: chi bundle uninstall #{@name}, then chi bundle install without --dev)"
        end
        raise InstallError, "#{@name} is installed normally; `chi bundle uninstall #{@name}` first, then chi bundle install --dev"
      end

      # A shipped name (in any case) from anything but this chi's own
      # shipped dir. A recorded source may be an older gem's (SourceIdentity
      # matches the path); an incoming one must be a dir in SHIPPED_DIR, so
      # a fork's lib/samagotchi/bundles/btw isn't chi's.
      def refuse_shipped_name
        return if @force || chi_copy?(@source)

        shipped = shipped_names.find { |name| name.casecmp?(@name) }
        return unless shipped

        what = shipped == @name ? "#{@name} is a bundle shipped with chi" : "#{@name} is #{shipped}, a bundle shipped with chi"
        raise InstallError, "#{what}; #{@source} isn't chi's copy of it (--force to install it anyway)"
      end

      # This source's SourceIdentity; one that looks shipped by its path (a
      # fork's lib/samagotchi/bundles/btw) but isn't a dir in the shipped
      # dir is its path, so it isn't taken for chi's btw. A recorded source
      # keeps the path match (older gems).
      def incoming_identity
        identity = SourceIdentity.of(@source)
        identity&.shipped? && !chi_copy?(@source) ? SourceIdentity.path(@source) : identity
      end

      # Whether +source+ is a dir in the shipped dir.
      def chi_copy?(source)
        path = File.realpath(source.to_s)
        File.directory?(path) && File.dirname(path) == File.realpath(@shipped_dir)
      rescue SystemCallError
        false
      end

      # The names of the bundles shipped with chi (their manifests'),
      # samagotchi-system and profiles included.
      def shipped_names
        Dir.glob(File.join(@shipped_dir, "*", "manifest.yml")).filter_map do |path|
          Manifest.read(dir: File.dirname(path)).name
        rescue Manifest::ValidationError
          nil
        end
      end

      # The source normalized to a dir (@bundle_dir; an owned one, extracted
      # from git/zip/tar, is cleaned up after #run) and its manifest.yml
      # (@manifest, nil when it has none and the install isn't strict).
      def load_source
        prepared = @prepared || PreparedSource.prepare(@source)
        @bundle_dir = @source_dir = prepared.dir
        @source_owned = prepared.owned
        @source_commit = prepared.commit
        @manifest = Manifest.read(dir: @bundle_dir)
        clash = @manifest.session_settings_clash
        raise InstallError, clash if clash
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

      # Copies the bundle's memories (MemoryFiles: the files: list, else
      # every *.md but README and the like) into the target dir and refreshes
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
        warn_unshipped_files
        warn_symlinked_files
        memory_files.each do |file_key|
          file_path = File.join(@bundle_dir, file_key)
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
            # Only --force gets here with a file in place: a copy keeps it.
            @replaced << file_key if File.exist?(target_path)
            @trash.copy(target_path) if File.exist?(target_path) && !FileUtils.identical?(file_path, target_path)
            FileUtils.cp(file_path, target_path)
            @owned << file_key
            @outcomes[file_key] = Merger::INSTALL
            @results[file_key] = { status: "installed" }
            update_target_index(@target_scope, target_path, file_key)
          end
        end
      end

      # The bundle's memories' basenames (MemoryFiles.select), once.
      def memory_files
        @memory_files ||= MemoryFiles.select(@bundle_dir, @manifest)
      end

      # A files: entry with no such *.md in the bundle installs nothing.
      def warn_unshipped_files
        missing = MemoryFiles.unshipped(@bundle_dir, @manifest)
        @warnings << "files: names #{missing.join(", ")}, which the bundle doesn't ship (not installed)" unless missing.empty?
      end

      # A memory that is a symlink isn't installed (MemoryFiles.symlinks).
      def warn_symlinked_files
        MemoryFiles.symlinks(@bundle_dir, @manifest).each { |name| @warnings << "#{name} is a symlink (not installed)" }
      end

      # An upgrade's 3-way merge of one file (Merger::Upgrade against the
      # base the last install recorded); a clean text merge replaces the file;
      # a conflict leaves it and is recorded in @conflicts for the agent step.
      def merge_memory(file_key, file_path, target_path)
        outcome = @outcomes[file_key] = upgrade_view.outcome(file_key)
        case outcome.status
        when :install
          FileUtils.cp(file_path, target_path)
          @results[file_key] = { status: "installed" }
        when :fast_forward
          save_marked_file(file_key, target_path)
          FileUtils.cp(file_path, target_path)
          @results[file_key] = { status: "updated", reason: "auto-merged (not edited)" }
        when :keep
          @results[file_key] = { status: "kept", reason: outcome == Merger::KEEP ? "bundle unchanged, local edits preserved" : "local edits already hold the bundle's changes" }
        when :noop
          @results[file_key] = { status: "skipped", reason: "already up to date" }
        when :merged
          if Merger.write_merged(target_path, outcome, @trash)
            @results[file_key] = { status: "merged", reason: "the bundle's changes joined to local edits" }
          else
            note_conflict(file_key, @outcomes[file_key] = Merger::CONFLICT.with(merge: TextMerge.failed(TextMerge::RACED)))
          end
        when :conflict
          note_conflict(file_key, outcome)
        else raise ArgumentError, "unknown outcome status #{outcome.status.inspect} for #{file_key}" # the base would move with nothing written
        end
        update_target_index(@target_scope, target_path, file_key)
      end

      # The file stays as it is, with the old base and the mark, in FileStanding's
      # words.
      def note_conflict(file_key, outcome)
        behind = upgrade_view.behind(file_key, outcome, @manifest&.version)
        @behind << behind
        @results[file_key] = { status: "conflict", reason: behind.state(dry_run: @dry_run) }
        @conflicts[file_key] = upgrade_view.paths(file_key)
        @warnings << "#{behind.line(dry_run: @dry_run)} (#{FileStanding::FORCE_TAKES})"
      end

      # What merged, on the record, a run that failed later too: the file holds the
      # merge whichever way the run ended. Never fails the run.
      def note_merges
        return if merged_files.empty?

        @provenance.note_merged(merged_files, version: @manifest&.version, trash: trash_dir)
      rescue StandardError => e
        @warnings << "merge not noted on the record (#{e.message})"
      end

      def upgrade_view
        @upgrade_view ||= Merger::Upgrade.new(provenance: @provenance, target_dir: @target_dir, source_dir: @bundle_dir)
      end

      # A marked file that equals its base, and the update goes ahead: the base
      # is known to be real (this chi's mark, or ShippedHistory), or no line of the
      # file goes. A copy is kept, and it says so. (Merger::Upgrade#outcome stops
      # an older chi's mark otherwise.)
      def save_marked_file(file_key, target_path)
        return unless @existing.files.dig(file_key, :conflict)

        @trash.copy(target_path)
        @warnings << "#{file_key} was marked as kept but matched its recorded base, so it took the update; your copy is in the trash"
      end

      # A dry run's verdict for one file, nothing written: an upgrade
      # classifies as merge_memory would (its status is the classification).
      def preview_memory(file_key, file_path, target_path)
        unless File.exist?(target_path) && !@force
          @results[file_key] = { status: "would_install" }
          return
        end

        if @upgrade && @existing
          outcome = upgrade_view.outcome(file_key)
          return note_conflict(file_key, outcome) if outcome.conflict?

          @results[file_key] = { status: outcome.merged? ? "would_merge" : outcome.status.to_s }
        elsif FileUtils.identical?(file_path, target_path)
          @results[file_key] = { status: "skipped", reason: "already up to date" }
        else
          @results[file_key] = { status: "would_skip" }
        end
      end

      # Strict mode: a memory written from the bundle whose sha256 differs
      # from its manifest's warns. One that wasn't copied (kept, skipped, a
      # dry run's keep and would_skip: a local edit isn't a bad download) or
      # was merged (merged, a dry run's would_merge) isn't checked.
      def verify_memory_checksums
        @bundle_md.each do |file_key|
          next if @conflicts.key?(file_key)

          status = @results[file_key] ? @results[file_key][:status].to_s : nil
          next if %w[kept keep kept_pruned fast_forward updated skipped would_skip merged would_merge].include?(status)

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
          marks: @behind + held_conflict_marks,
          incoming_dir: @bundle_dir,
          scripts_files: installed.script_files,
          context_providers: @manifest.context_providers,
          file_descriptions: @manifest.file_descriptions,
          session_settings: @manifest.session_settings,
          session_setting_types: @manifest.session_setting_types,
          settings: @manifest.settings,
          setting_types: @manifest.setting_types,
          dev: @dev
        )
        # Replaced by --force: an earlier merge into it no longer says anything true.
        @provenance.clear_merge_notes([], files: @replaced)
      end

      # The files a plain install skipped that are still marked conflict:
      # Provenance#write rebuilds their entries, and a file it left alone has
      # missed the bundle's change as much as before (its version may move on
      # all the same). One with the incoming bytes has nothing left to miss.
      # @return [Array<FileStanding::Behind>]
      def held_conflict_marks
        return [] if @upgrade || @existing.nil?

        kept = @owned.select { |key| @results.dig(key, :reason) == "already exists" && @existing.files.dig(key, :conflict) }
        kept.map { |key| held_mark(key) }
      end

      # The mark now speaks of this source's text, so what it says comes from that
      # text too: what was missed recomputed, an old reason dropped. No merge ran,
      # so one from an older chi, which can't name sections, keeps its own words.
      def held_mark(key)
        entry = @existing.files.fetch(key)
        return @existing.behind_entry(key, entry).with(version: @manifest.version) if InstalledBundle.legacy_mark?(entry)

        upgrade_view.behind(key, Merger::CONFLICT, @manifest.version)
      rescue SystemCallError
        FileStanding::Behind.new(file: key, version: @manifest.version)
      end

      # file key => the file whose content becomes its base: the one its
      # Merger::Outcome names (next_base). A file the bundle dropped but the
      # user kept stays recorded too, with the base it has.
      def upgrade_provenance_files
        files = {}
        @owned.each do |file_key|
          next unless File.exist?(File.join(@target_dir, file_key))

          files[file_key] = next_base(file_key, @outcomes.fetch(file_key))
        end
        @existing.files.each_key do |old_key_str|
          next if @bundle_md.include?(old_key_str)
          next unless @results[old_key_str] && @results[old_key_str][:status].to_s == "kept_pruned"

          files[old_key_str] = recorded_base(@provenance.base_path(old_key_str))
        end
        files
      end

      # The file an Outcome's base names. nil for a kept file with no base:
      # the user's file must not become one, or the next upgrade fast-forwards
      # over it.
      def next_base(file_key, outcome)
        case outcome.base
        when :recorded then recorded_base(@provenance.base_path(file_key))
        when :on_disk then File.join(@target_dir, file_key)
        when :incoming then File.join(@bundle_dir, file_key)
        else raise ArgumentError, "unknown base #{outcome.base.inspect} for #{file_key}" # nil would drop the base silently
        end
      end

      # +base_path+, nil when there is no base (Provenance#write's "keep the
      # entry, without one").
      def recorded_base(base_path) = File.exist?(base_path) ? base_path : nil

      # file key => its base's content source for a plain install. Skipped
      # for a local edit: keep the installed base, so the next upgrade still
      # sees the edit (not a fast-forward over it).
      def install_provenance_files
        files = @owned.each_with_object({}) do |file_key, map|
          target_path = File.join(@target_dir, file_key)
          next unless File.exist?(target_path)

          kept = @existing && @results.dig(file_key, :reason) == "already exists"
          map[file_key] = kept ? recorded_base(@provenance.base_path(file_key)) : target_path
        end
        files.merge(dropped_owned_files)
      end

      # file key => its base, for each file an earlier install owned that
      # this version doesn't ship and that is still on disk. A plain
      # install leaves such a file where it is, and keeps its record, so the
      # upgrade the summary points at still moves it to the trash
      # (prune_dropped_files); dropping the record orphaned it as a memory.
      def dropped_owned_files
        return {} unless @existing

        @existing.files.each_key.with_object({}) do |key, files|
          file_key = key.to_s
          next if @bundle_md.include?(file_key)
          next unless File.exist?(File.join(@target_dir, file_key))

          files[file_key] = recorded_base(@provenance.base_path(file_key))
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
          @warnings << "Skipped #{file_key} (already exists; #{FileStanding::FORCE_TAKES})"
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
            @warnings << "Kept #{key}: no longer in the bundle but edited locally (#{FileStanding::FORCE_MOVES})"
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
        @bundle_files ||= memory_files
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
