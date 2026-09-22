# frozen_string_literal: true

require "fileutils"
require_relative "installer"
require_relative "provenance"
require_relative "manifest"

module Samagotchi
  module MemoryBundle
    # Manages the built-in "samagotchi-system" bundle shipped inside the gem.
    #
    # The bundle lives at lib/samagotchi/bundles/system/ (manifest.yml + *.md)
    # and is lazily installed into the user's system memories directory
    # (~/.config/samagotchi/memories) on first Engine creation.
    #
    # Version is tied to Samagotchi::VERSION — a gem bump triggers a 3-way
    # upgrade: fast-forward when not edited, keep when bundle unchanged, conflict
    # keeps local edit with a warning.
    module SystemBundle
      BUNDLE_NAME = "samagotchi-system"
      SCOPE = "system"
      SKIP_ENV = "SAMAGOTCHI_SKIP_SYSTEM_BUNDLE"
      GEM_BUNDLE_DIR = File.expand_path("../bundles/system", __dir__)

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
          warn "[samagotchi-system] invalid gem manifest: #{e.message}"
          return false
        end

        provenance = Provenance.new(name: BUNDLE_NAME)
        data = provenance.read

        if data.nil?
          install_fresh(gem_manifest)
        elsif data[:version].to_s != gem_manifest.version.to_s
          upgrade_existing(gem_manifest, data)
        else
          # Already at desired version — still verify files present (e.g. user deleted one)
          verify_files_present(gem_manifest, data)
        end
      rescue StandardError => e
        warn "[samagotchi-system] ensure failed: #{e.class}: #{e.message}"
        false
      end

      def skip?
        val = ENV[SKIP_ENV].to_s.strip.downcase
        val == "1" || val == "true"
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
          installer.warnings.each { |w| warn "[samagotchi-system] #{w}" }
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
            warn "[samagotchi-system] kept local edit in #{file_key} (bundle v#{gem_manifest.version} has update — run: chi bundle status #{BUNDLE_NAME} / chi bundle diff #{BUNDLE_NAME} #{file_key})"
          end
        end
        installer.warnings.each { |w| warn "[samagotchi-system] #{w}" } unless installer.warnings.empty?
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
      private_class_method :install_fresh, :upgrade_existing, :verify_files_present
    end
  end
end
