# frozen_string_literal: true

require "fileutils"
require_relative "installer"
require_relative "provenance"
require_relative "manifest"
require_relative "merger"
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
    # fast-forward when not edited, keep when bundle unchanged, conflict keeps
    # local edit with a warning. An older shipped version is left alone, so an
    # old checkout never downgrades the installed bundle; it says so once.
    module SystemBundle
      BUNDLE_NAME = "samagotchi-system"
      SCOPE = "system"
      SKIP_ENV = "SAMAGOTCHI_SKIP_SYSTEM_BUNDLE"
      GEM_BUNDLE_DIR = File.expand_path("../bundles/system", __dir__)
      NOTED_FILE = "older_shipped_noted"

      module_function

      # What sync did (or, with dry_run, would do). status is :installed,
      # :updated, :restored (missing files put back), :up_to_date,
      # :newer_installed (left as is), :skipped (SKIP_ENV or no shipped
      # bundle) or :failed (error: says why); kept lists the files whose
      # local edits conflicted with the update and were kept.
      Result = Struct.new(:from, :to, :status, :kept, :warnings, :error, keyword_init: true) do
        def changed? = %i[installed updated restored].include?(status)
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
        result.kept.each do |file_key|
          Log.info(:memory, "system_local_edit_kept", echo: "[samagotchi-system] kept local edit in #{file_key} (bundle v#{result.to} has update — run: chi bundle status #{BUNDLE_NAME} / chi bundle diff #{BUNDLE_NAME} #{file_key})", file: file_key.to_s)
        end
        result.warnings.each { |w| Log.warn(:memory, "system_bundle_warning", echo: "[samagotchi-system] #{w}") }
        result.changed?
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
          data = Provenance.new(name: BUNDLE_NAME).read
          from = data && data[:version].to_s

          if data.nil?
            dry_run ? result(:installed, to: to) : install_fresh(to)
          elsif installed_newer?(from, to)
            # Running an older checkout/gem: never downgrade the user's system memories
            # (not even to restore a missing file). `chi self` shows installed vs shipped.
            result(:newer_installed, from: from, to: to)
          elsif from != to
            dry_run ? result(:updated, from: from, to: to, kept: conflicting(gem_manifest)) : upgrade_existing(from, to)
          else
            # Already at desired version — still verify files present (e.g. user deleted one)
            verify_files_present(gem_manifest, from, dry_run)
          end
        end
      rescue StandardError => e
        result(:failed, error: "ensure failed: #{e.class}: #{e.message}")
      end

      def result(status, from: nil, to: nil, kept: [], warnings: [], error: nil)
        Result.new(from: from, to: to, status: status, kept: kept, warnings: warnings, error: error)
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
        val == "1" || val == "true"
      end

      # Unparseable versions fall back to the old "any difference upgrades" behaviour.
      def installed_newer?(installed, shipped)
        installed, shipped = installed.to_s, shipped.to_s
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
          strict: true
        )
        installer.run
        result(:installed, to: to, warnings: installer.warnings)
      end

      # Installer handles fast_forward/keep/noop; a conflict keeps the local
      # file, and its own "Conflict in" warning is left out (kept says it).
      def upgrade_existing(from, to)
        installer = upgrade_installer
        installer.run
        kept = installer.conflicts.keys
        warnings = installer.warnings.reject { |w| kept.any? { |k| w.start_with?("Conflict in #{k}:") } }
        result(:updated, from: from, to: to, kept: kept, warnings: warnings)
      end

      # A file from the bundle missing on disk (the user deleted it) is put
      # back via the Installer (which classifies it as :install), without a
      # full reinstall.
      def verify_files_present(gem_manifest, version, dry_run)
        target_dir = Installer.system_dir
        missing = gem_manifest.files.keys.any? { |k| !File.exist?(File.join(target_dir, k)) }
        return result(:up_to_date, from: version, to: version) unless missing
        return result(:restored, from: version, to: version) if dry_run

        upgrade_installer.run
        result(:restored, from: version, to: version)
      end

      # The files an upgrade would keep: edited here and changed in the
      # shipped bundle (a dry run's kept).
      def conflicting(gem_manifest)
        provenance = Provenance.new(name: BUNDLE_NAME)
        gem_manifest.files.keys.map(&:to_s).sort.select do |key|
          Merger.classify(base_path: provenance.base_path(key), current_path: File.join(Installer.system_dir, key),
                          incoming_path: File.join(GEM_BUNDLE_DIR, key)) == :conflict
        end
      end

      def upgrade_installer
        Installer.new(source: GEM_BUNDLE_DIR, name: BUNDLE_NAME, scope: SCOPE, force: false, strict: true, upgrade: true)
      end
      private_class_method :with_lock, :note_newer_installed, :install_fresh, :upgrade_existing, :verify_files_present,
                           :upgrade_installer, :result, :conflicting
    end
  end
end
