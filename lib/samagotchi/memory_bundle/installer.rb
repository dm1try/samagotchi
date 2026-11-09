# frozen_string_literal: true

require "fileutils"
require_relative "file_digest"
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
    #   1. Normalize source → directory, refuse retired hooks, read manifest.yml (load_source)
    #   2. Refuse a bundle whose requires_chi this chi doesn't meet,
    #      unless force (refuse_too_new)
    #   3. Copy .md files to the target scope dir and update index.md
    #      (install_memories: plain, dry run, or an upgrade's 3-way merge)
    #   4. Hooks, guardrail rules, plugin, scripts into .bundles/<name>/
    #      (AssetInstaller)
    #   5. An upgrade prunes the files the bundle dropped
    #   6. Verify checksums (strict mode), warn about missing needs
    #   7. Write provenance (.bundles/<name>/manifest.json, write_provenance)
    #   8. Detect and report {{placeholders}}
    class Installer
      class InstallError < StandardError; end

      # What the run did to one file (a memory, or a rule, plugin or script:
      # AssetInstaller writes them too, and removes an older chi's hooks), as
      # #results holds it. word is
      # the report bucket (#summary): a real run's (:installed, :updated,
      # :merged, :kept, :kept_pruned, :kept_shared, :kept_own (a file left as
      # the user's), :up_to_date, :conflict, :removed) or a dry run's
      # (:would_install, :would_update, :would_merge, :would_skip, :would_remove,
      # and an upgrade's :fast_forward and :keep). state and action: the
      # memory's FileState and FileActions::Action, nil where none was read.
      # note: why, in words (a conflict's Behind#state, a kept file's reason).
      FileResult = Data.define(:word, :state, :action, :note) do
        def initialize(word:, state: nil, action: nil, note: nil) = super
      end

      attr_reader :results, :warnings, :placeholder_warnings, :conflicts

      # Each file this run left behind (FileStanding::Behind).
      attr_reader :behind

      # prepared: the source already normalized (a PreparedSource, which the
      # Installer then owns and cleans up as its own); nil normalizes source.
      # shipped_dir: the bundles this chi ships (a bundle of their names
      # installs from a dir in it only, unless force); ShippedUpdate,
      # Profile and SystemBundle pass the one they install from.
      # chi_version: the chi this install is for (Profile and ShippedUpdate
      # check their bundles against a version they are given); default this chi.
      def initialize(source:, name:, scope: nil, force: false, strict: true, upgrade: false, dry_run: false, prepared: nil,
                     shipped_dir: SourceNormalizer::SHIPPED_DIR, dev: false, chi_version: Samagotchi::VERSION,
                     refuse_mismatch: false)
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
        @chi_version = chi_version
        # `chi bundle install/upgrade` refuses a file whose bytes disagree with
        # its manifest sha before writing anything; the callers that only warn
        # (ShippedUpdate, SystemBundle, Profile) leave it unset.
        @refuse_mismatch = refuse_mismatch
        @results = {}
        @warnings = []
        @placeholder_warnings = []
        @conflicts = {}
        @behind = []
        @replaced = []
        @actions = {}
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
      def merged_files = with_word(:merged)

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
        refuse_too_new
        warn_unknown_keys(@manifest) if @manifest
        @target_scope, @target_dir = resolve_target
        @file_descriptions = @manifest&.file_descriptions || {}
        @provenance = Provenance.new(name: @name)
        @existing = @provenance.record
        check_source
        # A plain install over an installed bundle: its summary says so.
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
        installed = with_word(:installed)
        updated = with_word(:updated)
        merged = merged_files
        would_merge = with_word(:would_merge)
        kept = with_word(:kept, :keep, :kept_pruned)
        # A file whose bytes are already the bundle's was not left out: it is
        # up to date. Skipped keeps the files really left out -- the user's own
        # memory, and a dry run's would_skip.
        up_to_date = with_word(:up_to_date)
        skipped = with_word(:would_skip, :kept_own)
        would_install = with_word(:would_install)
        would_update = with_word(:would_update)
        fast_forward = with_word(:fast_forward)
        # An older chi's class-file hooks this run removes: a line of their
        # own, with why (AssetInstaller#retire_hooks).
        retired, removed = with_word(:removed).partition { |key| @results[key].note == AssetInstaller::RETIRED }
        would_retire, would_remove = with_word(:would_remove).partition { |key| @results[key].note == AssetInstaller::RETIRED }

        lines << "Installed: #{installed.join(", ")}" unless installed.empty?
        lines << "Updated: #{updated.join(", ")}" unless updated.empty?
        lines << "Would install: #{would_install.join(", ")}" unless would_install.empty?
        lines << "Would update: #{would_update.join(", ")}" unless would_update.empty?
        lines << "Fast-forward: #{fast_forward.join(", ")}" unless fast_forward.empty?
        lines << FileStanding.merged_line(merged, @manifest&.version) unless merged.empty?
        lines << FileStanding.merged_line(would_merge, @manifest&.version, dry_run: true) unless would_merge.empty?
        lines << "Removed (no longer in the bundle): #{removed.join(", ")}#{" (moved to #{trash_dir})" if trash_dir}" unless removed.empty?
        lines << "Would remove (no longer in the bundle): #{would_remove.join(", ")}" unless would_remove.empty?
        lines << "Removed (#{AssetInstaller::RETIRED}): #{retired.join(", ")}" unless retired.empty?
        lines << "Would remove (#{AssetInstaller::RETIRED}): #{would_retire.join(", ")}" unless would_retire.empty?
        lines << "Kept (local edits preserved): #{kept.join(", ")}" unless kept.empty?
        lines << "Up to date: #{up_to_date.join(", ")}" unless up_to_date.empty?
        lines << "Skipped: #{skipped.join(", ")}" unless skipped.empty?
        lines << trash_copy_line if trash_copy_line
        lines.concat(@warnings) unless @warnings.empty?
        lines.concat(@placeholder_warnings) unless @placeholder_warnings.empty?
        lines << reinstall_line if @reinstall

        lines.any? ? lines.join("\n") : "No files to install."
      end

      # The one words for a record whose source can't be read again (relative,
      # empty or gone): what `chi bundle upgrade NAME` refuses with and
      # ManifestStanding names. An upgrade from a copy switches the source.
      def self.source_gone_line(name, source)
        recorded = source.to_s.strip
        owner = recorded.empty? ? "#{name} has no recorded source" : "#{name}'s recorded source #{recorded} is gone"
        "#{owner}: chi bundle upgrade <path or URL of a copy>"
      end

      # The one words for a dev install an upgrade or a plain install meets:
      # it follows its source already. `Installer#refuse_dev_mismatch` raises
      # with them, and `chi bundle upgrade NAME` (which never reaches the
      # Installer for a dev record) prints the same line.
      def self.dev_install_line(name, source)
        "#{name} is a dev install of #{source}: it follows its source already " \
          "(to leave dev mode: chi bundle uninstall #{name}, then chi bundle install without --dev)"
      end

      # The line a refused install names one file with: the checksum warning and
      # the way past it. Only `chi bundle install/upgrade` refuses a mismatch
      # (--force skips the early check and keeps the post-write warning); the
      # callers that only warn (chi update, SystemBundle, a profile) never reach
      # this.
      # @param label [String] "a.md", "plugin plugin.rb", "script s.sh"
      # @param upgrade [Boolean] which command the hint names
      def self.mismatch_refusal(label, path, expected, upgrade:)
        warning = FileDigest.mismatch(label, path, expected)
        warning && "#{warning}; chi bundle #{upgrade ? "upgrade" : "install"} --force installs it anyway"
      end

      private

      # The files whose result has one of +words+, in the order they ran.
      def with_word(*words) = @results.select { |_, result| words.include?(result.word) }.keys

      # A plain install over a bundle that is already installed from the same
      # source: it rewrote the bundle's rules, plugin, scripts and its
      # record, and left a memory the user wrote as it was. So the line says
      # what changed, and points at the upgrade for the memories it kept.
      def reinstall_line
        line = "#{@name} was already installed from #{@source}: its rules, plugin and scripts " \
               "now match it and its record was rewritten"
        # :kept_own is the only way a memory is left out of a plain install
        # (its KEPT_OWN or HELD row): its bytes differ from the bundle's.
        if @results.any? { |_, r| r.word == :kept_own }
          line << "; your own copies of its memories were kept (chi bundle upgrade #{@name} " \
                 "merges the bundle's changes into them)"
        end
        line
      end

      # The steps that replace files, after the check of the files the manifest
      # names: memories, the bundle's own folder, then the files it dropped. The record isn't written yet, so a failed run is
      # retried as the same upgrade.
      # @return [AssetInstaller::Installed]
      # @raise [InstallError] a file system error (a file it can't read, a
      #   .trash it can't write)
      def replace_files
        assets = AssetInstaller.new(
          name: @name, source_dir: @bundle_dir, manifest: @manifest, provenance: @provenance, existing: @existing,
          results: @results, warnings: @warnings, conflicts: @conflicts, trash: @trash,
          force: @force, strict: @strict, upgrade: @upgrade, dry_run: @dry_run, dev: @dev, chi_version: @chi_version,
          refuse_mismatch: @refuse_mismatch
        )
        # Before the first write: a plugin or script the bundle lacks refuses the run with disk and record as they were.
        assets.check_named_files
        # And, for the commands that refuse it (--force aside), a file whose
        # bytes disagree with the sha its manifest declares.
        refuse_memory_mismatches
        assets.check_named_checksums
        write_pending
        install_memories
        installed = assets.run

        # Files the previous version shipped and this one doesn't.
        previous_files = @provenance.files_with_pending(@existing, target_dir: @target_dir)
        prune_dropped_files(previous_files, @bundle_md, @target_dir, @target_scope, @provenance) if @upgrade && @existing
        installed
      rescue SystemCallError => e
        raise InstallError, Trash.failure_message(e)
      end

      # The intent journal (Provenance#write_pending): the text of each memory
      # this run will change, noted before the first write, so a run that
      # stops before its record leaves files a retry still knows as the
      # bundle's.
      def write_pending
        return if @dry_run || @manifest.nil?

        incoming = memory_files.to_h { |key| [key, FileDigest.hex(File.join(@bundle_dir, key))] }
        incoming.reject! do |key, sha|
          sha.nil? || sha == FileDigest.hex(File.join(@target_dir, key))
        rescue SystemCallError
          true
        end
        @provenance.write_pending(version: @manifest.version, scope: @target_scope, target_dir: @target_dir, files: incoming) unless incoming.empty?
      rescue SystemCallError => e
        raise InstallError, Trash.failure_message(e)
      end

      # Before the first write, the bundle's own bytes against the sha its
      # manifest declares for each memory: `chi bundle install/upgrade` refuses
      # a mismatch (--force skips the check, and #verify_memory_checksums keeps
      # the post-write warning for the callers that only warn). A dev install
      # follows its own tree; a non-strict run has no shas to trust.
      # @raise [InstallError] one line per mismatched file
      def refuse_memory_mismatches
        return unless @refuse_mismatch && @strict && !@dev && !@force && @manifest

        lines = memory_files.filter_map do |file_key|
          self.class.mismatch_refusal(file_key, File.join(@bundle_dir, file_key),
                                      @manifest.checksum_for(file_key), upgrade: @upgrade)
        end
        raise InstallError, lines.join("\n") unless lines.empty?
      end

      # Who may install under this name (a manifest can take any name: a
      # repo calling itself guardrails). Sources compare by SourceIdentity
      # (a shipped dir by name, in any gem or checkout; a git URL without
      # #ref; a path resolved); one it can't place (an older record's
      # relative path) never refuses.
      #   - a name chi ships comes from a shipped dir only, unless --force
      #     (install and upgrade): the plugin and rules it replaces are chi's;
      #   - a plain install over a bundle from another source is refused,
      #     --force too (that overwrites files, it doesn't switch sources):
      #     it would delete the plugin and rules and rewrite the record;
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
          raise InstallError, self.class.dev_install_line(@name, @existing.source)
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
        Manifest::HooksRetired.refuse_source_files(@bundle_dir)
        @manifest = Manifest.read(dir: @bundle_dir)
        clash = @manifest.session_settings_clash
        raise InstallError, clash if clash
      rescue SourceNormalizer::UnknownSourceError => e
        raise InstallError, "Source normalization failed: #{e.message}"
      rescue Manifest::HooksRetired => e
        # A rule, not a strictness option: refused strict or not, a dry run too.
        raise InstallError, e.message
      rescue Manifest::ValidationError => e
        raise InstallError, e.message if @strict

        @warnings << "No manifest found — proceeding without strict manifest validation"
      end

      # A bundle whose requires_chi this chi doesn't meet is not installed at
      # all: --force is what installs it, and its plugin and rules then
      # warn that they won't load (AssetInstaller). The words come from
      # Manifest.requires_chi_failure, so the requirement is said one way.
      # A dry run is refused the same way: nothing there would load either.
      # @raise [InstallError]
      def refuse_too_new
        failure = Manifest.requires_chi_failure(@manifest&.requires_chi, @chi_version)
        return if failure.nil? || @force

        raise InstallError, "#{@name} can't be installed: #{failure} (chi update, or --force to install it anyway)"
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
      # their index lines. Each file's FileState and its command's row
      # (FileActions: INSTALL, FORCE, UPGRADE) say what happens: a dry run
      # only reads the row (preview_memory), a real run does it
      # (write_memory). Sets @bundle_md (every file the bundle ships) and
      # @owned: the bundle owns (records, upgrades, removes) only the files it
      # wrote, these from an earlier install and the ones written now. A
      # same-name file that was already there is the user's: skipped and never
      # recorded (the not-owned rows).
      def install_memories
        @bundle_md = []
        @owned = []
        warn_unshipped_files
        warn_symlinked_files
        memory_files.each do |file_key|
          @bundle_md << file_key
          note_overlay(file_key, @target_dir)
          state = FileState.of(file_key, record: @existing, provenance: @provenance, target_dir: @target_dir,
                                         source_dir: @bundle_dir)
          action = FileActions.for(memory_command, state)
          next preview_memory(file_key, state, action) if @dry_run

          @owned << file_key unless action.record == :not_owned
          write_memory(file_key, state, action)
        end
      end

      # The table a memory's row is read from: --force (install or upgrade:
      # one code path), an upgrade over a record, else a plain install.
      def memory_command
        if @force then :force
        elsif @upgrade && @existing then :upgrade
        else :install
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

      # One memory's row, done: the bundle's text written (a copy of other
      # bytes in the trash first), the text merge's result written, the file
      # kept or left behind (a conflict, recorded in @conflicts for the agent
      # step), or skipped as the user's; its index line refreshed. A :decide
      # cell is the upgrade's (Merger::Upgrade#decision: the text merge or the
      # legacy guard, against the base the last install recorded).
      def write_memory(file_key, state, action)
        file_path = state.paths[:incoming]
        target_path = state.paths[:current]
        decision = upgrade_view.decision(file_key, state) if action.do == :decide
        action = decision.action if decision
        @actions[file_key] = action
        @replaced << file_key if @force && state.digests.disk
        result = FileResult.new(word: action.word, state: state, action: action)
        case action.do
        when :write_incoming
          save_first(file_key, file_path, target_path) if action.save_first
          FileUtils.cp(file_path, target_path)
          @results[file_key] = action.word == :updated ? result.with(note: "auto-merged (not edited)") : result
        when :merge
          if Merger.write_merged(target_path, decision.outcome, @trash)
            @results[file_key] = result.with(note: "the bundle's changes joined to local edits")
          else
            @actions[file_key] = FileActions::BEHIND
            note_conflict(file_key, Merger::CONFLICT.with(merge: TextMerge.failed(TextMerge::RACED)), state)
          end
        when :keep
          if action.behind?
            note_conflict(file_key, (decision || upgrade_view.decision(file_key, state)).outcome, state)
          elsif action.word == :kept
            @results[file_key] = result.with(note: decision.nil? || decision.outcome == Merger::KEEP ? "bundle unchanged, local edits preserved" : "local edits already hold the bundle's changes")
          else
            @results[file_key] = result
          end
        when :skip
          @results[file_key] = result.with(note: "already exists")
          @warnings << "Skipped #{file_key} (already exists; #{FileStanding::FORCE_TAKES})"
        when :refuse then refuse_unreadable(file_key, target_path)
        else raise ArgumentError, "no install step for #{action.do.inspect} (#{file_key})" # the base would move with nothing written
        end
        update_target_index(@target_scope, target_path, file_key, owned: action.record != :not_owned)
      end

      # A file chi can't read: whether it was edited can't be told, so the
      # run stops (the read raises; Trash.failure_message says nothing was
      # lost).
      def refuse_unreadable(file_key, target_path)
        FileDigest.hex(target_path)
        raise InstallError, "#{file_key} can't be read"
      end

      # The file stays as it is, with the old base and the mark, in FileStanding's
      # words.
      def note_conflict(file_key, outcome, state = nil)
        behind = upgrade_view.behind(file_key, outcome, @manifest&.version)
        @behind << behind
        @results[file_key] = FileResult.new(word: :conflict, state: state, action: state && FileActions::BEHIND,
                                            note: behind.state(dry_run: @dry_run))
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

      # A save_first cell: the file's other bytes go to the trash before the
      # bundle's text replaces them. Under an upgrade that is a marked file
      # that equals its base, and the update goes ahead: the base is known to
      # be real (this chi's mark, or ShippedHistory), or no line of the file
      # goes (Merger::Upgrade's legacy guard stops an older chi's mark
      # otherwise), and it says so.
      def save_first(file_key, file_path, target_path)
        return unless File.exist?(target_path) && !FileUtils.identical?(file_path, target_path)

        @trash.copy(target_path)
        return if @force

        @warnings << "#{file_key} was marked as kept but matched its recorded base, so it took the update; your copy is in the trash"
      end

      # A dry run's word for an action's (the real run's): what would happen,
      # nothing written. A conflict is reported as the real run would.
      DRY_WORDS = { installed: :would_install, updated: :fast_forward, kept: :keep, merged: :would_merge,
                    kept_own: :would_skip, up_to_date: :up_to_date }.freeze

      # A dry run's verdict for one file: its row read, not done (a :decide
      # cell's text merge runs on temp copies). --force would install every
      # file, unread.
      def preview_memory(file_key, state, action)
        preview_trash_copy(file_key, state, action)
        return @results[file_key] = FileResult.new(word: :would_install, state: state, action: action) if @force
        return refuse_unreadable(file_key, state.paths[:current]) if action.do == :refuse

        decision = upgrade_view.decision(file_key, state) if action.do == :decide || action.behind?
        action = decision.action if decision
        return note_conflict(file_key, decision.outcome, state) if action.behind?

        preview_trash_copy(file_key, state, action)
        @results[file_key] = FileResult.new(word: DRY_WORDS.fetch(action.word), state: state, action: action)
      end

      def preview_trash_copy(file_key, state, action)
        return unless action.save_first

        current = state.paths[:current]
        incoming = state.paths[:incoming]
        return unless File.file?(current) && !FileUtils.identical?(incoming, current)

        @warnings << "Would copy to the trash first: #{file_key}"
      end

      # Strict mode: a memory that takes the bundle's text (Action#takes_source?:
      # a new or missing file, --force, an upgrade's or a re-install's
      # fast-forward, a merge into a local edit) warns when the bundle's file
      # differs from its manifest's sha256. One kept or skipped isn't checked
      # (it takes nothing from the bundle). What is checked is the source
      # file, the bytes the write or merge takes, so a dry run checks what it
      # would bring in, never the user's bytes on disk. A dev install follows
      # its own tree; chi bundle check flags its stale shas instead.
      def verify_memory_checksums
        return if @dev

        @bundle_md.each do |file_key|
          result = @results[file_key]
          next unless result&.action&.takes_source?

          warning = FileDigest.mismatch(file_key, result.state.paths[:incoming], @manifest.checksum_for(file_key))
          @warnings << warning if warning
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
      # version, the plugin's new sha, and the old base for each
      # conflicted file, marked conflict (chi bundle status shows it).
      # Skipping it left the replaced plugin failing its sha check.
      # @param installed [AssetInstaller::Installed]
      def write_provenance(installed)
        @provenance.write(
          files: @upgrade && @existing ? upgrade_provenance_files : install_provenance_files,
          scope: @target_scope,
          version: @manifest.version,
          source_path: @source,
          trust_level: @manifest.trust_level,
          source_commit: @source_commit,
          guardrails_files: installed.guardrail_files,
          plugin_file: installed.plugin_file,
          plugin_required: @manifest.plugin&.dig(:required) == true,
          requires_chi: @manifest.requires_chi,
          needs: @manifest.needs,
          marks: @behind + held_conflict_marks,
          incoming_dir: @bundle_dir,
          scripts_files: installed.script_files,
          context_providers: @manifest.context_providers,
          block_renderers: @manifest.block_renderers,
          file_descriptions: @manifest.file_descriptions,
          session_settings: @manifest.session_settings,
          session_setting_types: @manifest.session_setting_types,
          settings: @manifest.settings,
          setting_types: @manifest.setting_types,
          dev: @dev,
          manifest_from: @bundle_dir
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

        kept = @owned.select { |key| @actions[key].record == :hold_mark }
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

          files[file_key] = next_base(file_key, @actions.fetch(file_key))
        end
        @existing.files.each_key do |old_key_str|
          next if @bundle_md.include?(old_key_str)
          next unless @results[old_key_str]&.word == :kept_pruned

          files[old_key_str] = recorded_base(@provenance.base_path(old_key_str))
        end
        files
      end

      # The file an action's next_base names. nil for a kept file with no
      # base: the user's file must not become one, or the next upgrade
      # fast-forwards over it.
      def next_base(file_key, action)
        case action.next_base
        when :recorded then recorded_base(@provenance.base_path(file_key))
        when :on_disk then File.join(@target_dir, file_key)
        when :incoming then File.join(@bundle_dir, file_key)
        else raise ArgumentError, "unknown base #{action.next_base.inspect} for #{file_key}" # nil would drop the base silently
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
          next unless File.exist?(File.join(@target_dir, file_key))

          map[file_key] = next_base(file_key, @actions.fetch(file_key))
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

      # A file the previous version installed that this one doesn't ship:
      # its FileState's dropped kind and the UPGRADE (or FORCE) row. An
      # unedited one is moved to the trash (with its index line removed), as
      # is any with --force; an edited one is kept with a note, and one
      # another bundle lists too stays.
      def prune_dropped_files(previous_files, bundle_files, target_dir, scope, provenance)
        previous_files.each_key do |key|
          next if bundle_files.include?(key)

          target = File.join(target_dir, key)
          state = FileState.of(key, record: @existing, provenance: provenance, target_dir: target_dir, source_dir: @bundle_dir,
                                    shipped: false, claimants: ->(k) { Provenance.claimants(k, scope: scope, except: @name) })
          action = if state.kind == :unreadable
                     unreadable_dropped(state, target)
                   else
                     FileActions.for(@force ? :force : :upgrade, state)
                   end
          result = FileResult.new(word: action.word, state: state, action: action)
          case action.word
          when :kept_shared
            others = state.shared_with.join(", ")
            @results[key] = result.with(note: "bundle #{others} has it too")
            @warnings << "Kept #{key}: no longer in the bundle, but bundle #{others} has it too"
          when :removed
            @results[key] = result.with(word: @dry_run ? :would_remove : :removed, note: "no longer in the bundle")
            next if @dry_run

            @trash.move(target)
            remove_target_index(scope, key)
          when :kept_pruned
            @results[key] = result.with(note: "local edits preserved")
            @warnings << "Kept #{key}: no longer in the bundle but edited locally (#{FileStanding::FORCE_MOVES})"
          end
        end
      end

      # A dropped file chi can't read, in the order the rows are asked: kept
      # when another bundle lists it, moved unread with --force; otherwise
      # whether it was edited can't be told, and the read raises (the run
      # stops, nothing lost).
      def unreadable_dropped(state, target)
        return FileActions::KEPT_SHARED if state.shared_with.any?
        return FileActions::REMOVE if @force

        FileDigest.hex(target)
        raise InstallError, "#{state.key} can't be read"
      end

      # One warning per manifest key this chi's parser never reads (docs/cli.md's
      # unknown-key): it is ignored, so the advice is chi's own. A dry run warns
      # too: the key is in the manifest either way.
      def warn_unknown_keys(manifest)
        manifest.unknown_keys.each do |key|
          @warnings << "#{Manifest.unknown_key_line(key)}; a newer chi reads it from the installed manifest " \
                       "(chi update, then chi bundle status #{manifest.name} says whether it needs chi bundle upgrade #{manifest.name})"
        end
      end

      # Not fatal, like update_target_index: a warning says so.
      def remove_target_index(scope, file_key)
        IndexUpdater.remove_index(scope, file_key.delete_suffix(".md"), target_dir: @target_dir)
        IndexUpdater.remove_index(scope, file_key, target_dir: @target_dir) # legacy "name.md" line
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
