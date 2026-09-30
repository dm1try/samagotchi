# frozen_string_literal: true

require_relative "../memory_bundle/manifest"
require_relative "../memory_bundle/profile"
require_relative "../memory_bundle/source"
require_relative "../memory_bundle/system_bundle"

module Samagotchi
  module Bootstrap
    # chi bootstrap's bundles step: the system bundle and the shipped
    # profiles, into the config dir the process ENV names (Provenance and
    # the Installer resolve their paths from it, not from bootstrap's env:).
    # A seam: in-process specs pass their own.
    class Bundles
      def initialize(shipped_dir: MemoryBundle::SourceNormalizer::SHIPPED_DIR)
        @shipped_dir = shipped_dir
      end

      # @return [MemoryBundle::SystemBundle::Result]
      def sync_system(dry_run: false) = MemoryBundle::SystemBundle.sync(dry_run: dry_run)

      # @return [MemoryBundle::Profile::InstallResult]
      def install(profile, dry_run: false)
        MemoryBundle::Profile.install(dir(profile), shipped_dir: @shipped_dir, dry_run: dry_run)
      end

      # The members installing +profile+ would install now.
      def to_install(profile)
        MemoryBundle::Profile.to_install(MemoryBundle::Manifest.read(dir: dir(profile)))
      end

      private

      def dir(profile) = File.join(@shipped_dir, profile)
    end
  end
end
