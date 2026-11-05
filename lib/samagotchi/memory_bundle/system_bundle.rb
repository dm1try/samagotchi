# frozen_string_literal: true

require "fileutils"
require_relative "installer"
require_relative "provenance"
require_relative "manifest"
require_relative "index_updater"
require_relative "memory_files"
require_relative "merger"
require_relative "remerge"
require_relative "trash"
require_relative "../log"

module Samagotchi
  module MemoryBundle
    # Manages the built-in "samagotchi-system" bundle shipped inside the gem.
    #
    # The bundle lives at lib/samagotchi/bundles/system/ (manifest.yml + *.md)
    # and is lazily installed into the user's system memories directory
    # (~/.config/samagotchi/memories) on first Engine creation.
    #
    # A newer shipped version (manifest.yml) triggers a 3-way upgrade:
    # fast-forward when not edited, keep when bundle unchanged, a clean text
    # merge replaces the file, a real conflict keeps local edit with a warning.
    # An older shipped version is left alone, so an
    # old checkout never downgrades the installed bundle; it says so once.
    module SystemBundle
      BUNDLE_NAME = "samagotchi-system"
      SCOPE = "system"
      SKIP_ENV = "SAMAGOTCHI_SKIP_SYSTEM_BUNDLE"
      GEM_BUNDLE_DIR = File.expand_path("../bundles/system", __dir__)
      NOTED_FILE = "older_shipped_noted"

      module_function

      # What sync did (or, with dry_run, would do). status is :installed,
      # :updated, :restored (missing files put back), :merged (a file marked
      # conflict merged at the same version, Remerge), :up_to_date,
      # :newer_installed (left as is), :skipped (SKIP_ENV or no shipped
      # bundle) or :failed (error: says why); merged lists the files a text
      # merge replaced (trash_copy says where the old ones went), behind each file
      # that stays behind (FileStanding::Behind). ensure! says only what an upgrade
      # left behind: a file that was already behind isn't news at every start.
      Result = Struct.new(:from, :to, :status, :merged, :behind, :trash_copy, :warnings, :error, keyword_init: true) do
        def changed? = %i[installed updated restored merged].include?(status)

        def kept = Array(behind).map(&:file)
      end

      # Ensure the system bundle is installed and up-to-date.
      # Idempotent and warn-only: never raises to callers.
      # Safe for TUI and non-TUI (web/worker) paths — Engine calls this.
      def ensure!
        result = sync
        case result.status
        when :failed
          Log.error(:memory, "system_bundle_failed", echo: "[samagotchi-system] #{result.error}")
        when :newer_installed
          with_lock { note_newer_installed(result.from, result.to) }
        end
        unless result.merged.empty?
          note = [FileStanding.merged_line(result.merged, result.to), result.trash_copy].compact.join("; ")
          Log.info(:memory, "system_bundle_merged", echo: "[samagotchi-system] #{note}", files: result.merged.join(","), to: result.to.to_s)
        end
        if result.status == :updated
          result.behind.each do |file|
            Log.info(:memory, "system_file_behind", echo: "[samagotchi-system] #{file.line} (#{FileStanding.diff_hint(BUNDLE_NAME, file.file)})", file: file.file)
          end
        end
        result.warnings.each { |w| Log.warn(:memory, "system_bundle_warning", echo: "[samagotchi-system] #{w}") }
        result.changed?
      end

      # The merges no chi update has shown (MergeNote): ask before .sync, whose
      # own merges its caller reports itself.
      # @return [Array<FileStanding::MergeNote>]
      def merge_notes
        Provenance.new(name: BUNDLE_NAME).record&.merge_notes || []
      rescue StandardError
        []
      end

      # Those notes have been shown (Provenance#clear_merge_notes), under the lock.
      def clear_merge_notes(notes, files: [])
        with_lock { Provenance.new(name: BUNDLE_NAME).clear_merge_notes(notes, files: files) }
      rescue StandardError
        nil
      end

      # Install, upgrade or repair the installed system bundle to match the
      # shipped one, under the lock. Never raises; logs nothing (ensure!
      # and chi update report the Result).
      # @param dry_run [Boolean] classify only, write nothing
      # @return [Result]
      def sync(dry_run: false)
        return result(:skipped, error: "#{SKIP_ENV} is set") if skip?
        return result(:skipped, error: "no shipped system bundle") unless File.directory?(GEM_BUNDLE_DIR)

        begin
          gem_manifest = Manifest.read(dir: GEM_BUNDLE_DIR)
        rescue Manifest::ValidationError => e
          return result(:failed, error: "invalid gem manifest: #{e.message}")
        end
        to = gem_manifest.version.to_s

        with_lock do
          bundle = Provenance.new(name: BUNDLE_NAME).record
          from = bundle&.version.to_s

          if bundle.nil?
            dry_run ? result(:installed, to: to) : install_fresh(to)
          elsif installed_newer?(from, to)
            # Running an older checkout/gem: never downgrade the user's system memories
            # (not even to restore a missing file). `chi self` shows installed vs shipped.
            result(:newer_installed, from: from, to: to, behind: bundle.behind_files)
          elsif from != to
            dry_run ? planned_update(gem_manifest, from, to) : upgrade_existing(from, to)
          else
            # Already at desired version — still verify files present (e.g. user deleted one)
            # and retry the files marked conflict.
            verified = verify_files_present(gem_manifest, from, dry_run)
            next remerge(bundle, verified, dry_run) if verified.status == :up_to_date

            verified.tap { |done| done.behind = Provenance.new(name: BUNDLE_NAME).record.behind_files }
          end
        end
      rescue Installer::InstallError => e
        result(:failed, error: e.message)
      rescue SystemCallError => e
        result(:failed, error: Trash.failure_message(e))
      rescue StandardError => e
        result(:failed, error: "ensure failed: #{e.class}: #{e.message}")
      end

      def result(status, from: nil, to: nil, merged: [], behind: [], trash_copy: nil, warnings: [], error: nil)
        Result.new(from: from, to: to, status: status, merged: merged, behind: behind, trash_copy: trash_copy,
                   warnings: warnings, error: error)
      end

      # Parallel chi starts on one config dir take turns: the second one reads
      # the provenance the first one wrote, instead of installing over it and
      # warning "Skipped … already exists" for every file.
      def with_lock
        dir = Provenance.bundles_dir
        FileUtils.mkdir_p(dir)
        File.open(File.join(dir, "#{BUNDLE_NAME}.lock"), File::RDWR | File::CREAT, 0o644) do |f|
          f.flock(File::LOCK_EX)
          yield
        end
      end

      def skip?
        val = ENV[SKIP_ENV].to_s.strip.downcase
        %w[1 true].include?(val)
      end

      # Unparseable versions fall back to the old "any difference upgrades" behaviour.
      def installed_newer?(installed, shipped)
        installed = installed.to_s
        shipped = shipped.to_s
        return false unless Gem::Version.correct?(installed) && Gem::Version.correct?(shipped)

        Gem::Version.new(installed) > Gem::Version.new(shipped)
      end

      # One line per installed/shipped pair, so an old worktree (and each of its
      # workers) says it once instead of on every start. The pairs already noted
      # sit in the bundle's provenance dir; ensure! holds the lock here.
      def note_newer_installed(installed, shipped)
        pair = "#{installed} #{shipped}"
        path = File.join(Provenance.new(name: BUNDLE_NAME).bundle_dir, NOTED_FILE)
        noted = File.exist?(path) ? File.readlines(path, chomp: true) : []
        return if noted.include?(pair)

        Log.warn(:memory, "system_bundle_newer", echo: "[samagotchi-system] installed system bundle #{installed} is newer than this chi's #{shipped}; left as is", installed: installed.to_s, shipped: shipped.to_s)
        File.write(path, "#{pair}\n", mode: "a")
      end

      def install_fresh(to)
        installer = Installer.new(
          source: GEM_BUNDLE_DIR,
          name: BUNDLE_NAME,
          scope: SCOPE,
          force: false,
          strict: true,
          shipped_dir: File.dirname(GEM_BUNDLE_DIR)
        )
        installer.run
        result(:installed, to: to, warnings: installer.warnings)
      end

      # Installer handles fast_forward/keep/noop; a conflict keeps the local
      # file, and its own warning is left out (behind says it).
      def upgrade_existing(from, to)
        installer = upgrade_installer
        installer.run
        behind = installer.behind
        warnings = installer.warnings.reject { |w| behind.any? { |file| w.start_with?(file.line) } }
        result(:updated, from: from, to: to, merged: installer.merged_files, behind: behind, trash_copy: installer.trash_copy_line, warnings: warnings)
      end

      # A file from the bundle missing on disk (the user deleted it) is put
      # back, and nothing else: at the same version a checkout can carry other
      # text, so no other file is merged here (Remerge has its guard), and a live
      # session's guardrails, plugin and scripts stay where they are.
      def verify_files_present(gem_manifest, version, dry_run)
        target_dir = MemoryPaths.system_dir
        missing = MemoryFiles.select(GEM_BUNDLE_DIR, gem_manifest).reject { |key| File.exist?(File.join(target_dir, key)) }
        return result(:up_to_date, from: version, to: version) if missing.empty?
        return result(:restored, from: version, to: version) if dry_run

        warnings = missing.filter_map { |key| restore_file(key, gem_manifest.file_descriptions[key]) }
        result(:restored, from: version, to: version, warnings: warnings)
      end

      # @return [String, nil] a warning: the file is in place, its index line isn't
      def restore_file(key, description)
        source = File.join(GEM_BUNDLE_DIR, key)
        target = File.join(MemoryPaths.system_dir, key)
        FileUtils.cp(source, target)
        Provenance.new(name: BUNDLE_NAME).record_restored(key, source, description: description)
        begin
          IndexUpdater.update_index(SCOPE, key.delete_suffix(".md"), File.size(target), description, source: BUNDLE_NAME)
          nil
        rescue StandardError => e
          "index.md: line for #{key.delete_suffix(".md")} not updated (#{e.message})"
        end
      end

      # An up-to-date bundle's marked files, retried. No marks: nothing is read.
      def remerge(bundle, verified, dry_run)
        done = Remerge.new(name: BUNDLE_NAME, scope: SCOPE, target_dir: MemoryPaths.system_dir, source_dir: GEM_BUNDLE_DIR, record: bundle)
                      .run(dry_run: dry_run)
        status = done.merged.empty? ? :up_to_date : :merged
        result(status, from: verified.from, to: verified.to, merged: done.merged, behind: done.behind, trash_copy: done.trash_copy, warnings: done.warnings)
      end

      # A dry run's answer for an upgrade: what it would merge and keep, among
      # the files installed by the bundle that are edited here and changed in
      # the shipped bundle. The manifest's files:, not MemoryFiles.select: see
      # Merger::Upgrade#forecast.
      def planned_update(gem_manifest, from, to)
        provenance = Provenance.new(name: BUNDLE_NAME)
        owned = provenance.record&.files&.keys || []
        forecast = Merger::Upgrade.new(provenance: provenance, target_dir: MemoryPaths.system_dir, source_dir: GEM_BUNDLE_DIR)
                                  .forecast(gem_manifest.files.keys.map(&:to_s).sort & owned, version: to)
        result(:updated, from: from, to: to, merged: forecast.merged, behind: forecast.behind)
      end

      def upgrade_installer
        Installer.new(source: GEM_BUNDLE_DIR, name: BUNDLE_NAME, scope: SCOPE, force: false, strict: true, upgrade: true,
                      shipped_dir: File.dirname(GEM_BUNDLE_DIR))
      end
      private_class_method :with_lock, :note_newer_installed, :install_fresh, :upgrade_existing, :verify_files_present, :restore_file, :remerge,
                           :upgrade_installer, :result, :planned_update
    end
  end
end
