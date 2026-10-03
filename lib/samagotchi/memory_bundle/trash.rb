# frozen_string_literal: true

require "fileutils"
require_relative "../memory_paths"

module Samagotchi
  module MemoryBundle
    # Where a bundle operation puts the memory files it takes away
    # (uninstall, an upgrade's dropped file): moved, never deleted, into
    # <system memories>/.bundles/.trash/<bundle>-<YYYYmmdd-HHMMSS>/, one dir
    # per operation (-2, -3… when one already has that name). A dot dir, so
    # Provenance.each_installed never reads it as a bundle. Nothing prunes
    # it: the user deletes it when sure.
    class Trash
      def self.root(bundles_dir: MemoryPaths.bundles_dir)
        File.join(bundles_dir, ".trash")
      end

      # The dir, once a file was moved (nil before).
      attr_reader :dir

      def initialize(name, now: Time.now, bundles_dir: MemoryPaths.bundles_dir)
        @name = name.to_s
        @now = now
        @bundles_dir = bundles_dir
        @dir = nil
      end

      # Moves +path+ into the trash dir (created on the first call).
      # @return [String] the file's new path
      def move(path)
        dest = File.join(ensure_dir, File.basename(path))
        FileUtils.mv(path, dest)
        dest
      end

      private

      def ensure_dir
        return @dir if @dir

        base = File.join(self.class.root(bundles_dir: @bundles_dir), "#{@name}-#{@now.strftime("%Y%m%d-%H%M%S")}")
        FileUtils.mkdir_p(File.dirname(base))
        candidate = base
        n = 1
        loop do
          Dir.mkdir(candidate)
          break
        rescue Errno::EEXIST
          n += 1
          candidate = "#{base}-#{n}"
        end
        @dir = candidate
      end
    end
  end
end
