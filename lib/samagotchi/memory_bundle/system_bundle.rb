# frozen_string_literal: true

require "fileutils"
require_relative "installer"
require_relative "provenance"
require_relative "manifest"
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

      # Ensure the system bundle is installed and up-to-date.
      # Idempotent and warn-only: never raises to callers.
      # Safe for TUI and non-TUI (web/worker) paths — Engine calls this.
      def ensure!
        return false if skip?
        return false unless File.directory?(GEM_BUNDLE_DIR)

        begin
          gem_manifest = Manifest.read(dir: GEM_BUNDLE_DIR)
        rescue Manifest::ValidationError => e
          Log.error(:memory, "system_manifest_invalid", echo: "[samagotchi-system] invalid gem manifest: #{e.message}")
          return false
        end

        with_lock do
          data = Provenance.new(name: BUNDLE_NAME).read

          if data.nil?
            install_fresh(gem_manifest)
          elsif installed_newer?(data[:version], gem_manifest.version)
            # Running an older checkout/gem: never downgrade the user's system memories
            # (not even to restore a missing file). `chi self` shows installed vs shipped.
            note_newer_installed(data[:version], gem_manifest.version)
            false
          elsif data[:version].to_s != gem_manifest.version.to_s
            upgrade_existing(gem_manifest, data)
          else
            # Already at desired version — still verify files present (e.g. user deleted one)
            verify_files_present(gem_manifest, data)
          end
        end
      rescue StandardError => e
        Log.error(:memory, "system_bundle_failed", echo: "[samagotchi-system] ensure failed: #{e.class}: #{e.message}", error: e.class.name)
        false
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

      def install_fresh(gem_manifest)
        installer = Installer.new(
          source: GEM_BUNDLE_DIR,
          name: BUNDLE_NAME,
          scope: SCOPE,
          force: false,
          strict: true
        )
        _nd, _manifest = installer.run
        unless installer.warnings.empty?
          installer.warnings.each { |w| Log.warn(:memory, "system_bundle_warning", echo: "[samagotchi-system] #{w}") }
        end
        true
      end

      def upgrade_existing(gem_manifest, _existing_data)
        installer = Installer.new(
          source: GEM_BUNDLE_DIR,
          name: BUNDLE_NAME,
          scope: SCOPE,
          force: false,
          strict: true,
          upgrade: true
        )
        _nd, _manifest = installer.run
        # Installer already handled fast_forward/keep/noop. Conflicts are kept with warning.
        if installer.conflicts.any?
          installer.conflicts.each do |file_key, _info|
            Log.info(:memory, "system_local_edit_kept", echo: "[samagotchi-system] kept local edit in #{file_key} (bundle v#{gem_manifest.version} has update — run: chi bundle status #{BUNDLE_NAME} / chi bundle diff #{BUNDLE_NAME} #{file_key})", file: file_key.to_s)
          end
        end
        installer.warnings.each { |w| Log.warn(:memory, "system_bundle_warning", echo: "[samagotchi-system] #{w}") } unless installer.warnings.empty?
        true
      end

      def verify_files_present(gem_manifest, data)
        # If any file from the bundle is missing on disk but provenance says it should exist,
        # reinstall that file via Installer (which will classify as :install). This handles
        # accidental user deletion without forcing a full reinstall.
        target_dir = Installer.system_dir
        missing = gem_manifest.files.keys.any? { |k| !File.exist?(File.join(target_dir, k)) }
        return false unless missing

        installer = Installer.new(
          source: GEM_BUNDLE_DIR,
          name: BUNDLE_NAME,
          scope: SCOPE,
          force: false,
          strict: true,
          upgrade: true
        )
        _nd, _manifest = installer.run
        true
      end
      private_class_method :with_lock, :note_newer_installed, :install_fresh, :upgrade_existing, :verify_files_present
    end
  end
end
