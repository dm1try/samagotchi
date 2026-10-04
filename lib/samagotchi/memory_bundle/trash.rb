# frozen_string_literal: true

require "fileutils"
require_relative "../memory_paths"

module Samagotchi
  module MemoryBundle
    # Where a bundle operation puts the memory files it takes away
    # (uninstall, an upgrade's dropped file): moved, never deleted, into
    # <system memories>/.bundles/.trash/<bundle>-<YYYYmmdd-HHMMSS>/, one dir
    # per operation (-2, -3… when one already has that name). A dot dir, so
    # Provenance.each_installed never reads it as a bundle.
    #
    # `chi bundle trash` lists and empties the trash.
    class Trash
      # A single trash entry (one directory in the trash).
      Entry = Data.define(:name, :path, :time, :files, :bytes)

      def self.root(bundles_dir: MemoryPaths.bundles_dir)
        File.join(bundles_dir, ".trash")
      end

      # Returns an array of {Entry} for every real directory directly inside
      # the trash, oldest first.  A missing or empty trash gives [].
      #
      # +now+ is the reference time (default: Time.now); used only when a
      # directory name has no timestamp (mtime fallback).
      def self.entries(bundles_dir: MemoryPaths.bundles_dir, now: Time.now)
        trash_dir = root(bundles_dir: bundles_dir)
        return [] unless Dir.exist?(trash_dir)

        Dir.children(trash_dir)
          .select { |c| real_dir?(File.join(trash_dir, c)) }
          .map { |name| entry_for(trash_dir, name, now) }
          .sort_by(&:time)
      end

      # Deletes every entry that matches the filter, returning the entries
      # that were (or would be) deleted.
      #
      # +older_than_days+ nil = all; a positive integer keeps newer dirs.
      # +dry_run+ true = only return what would be deleted.
      # +now+ reference time (default: Time.now).
      def self.empty!(bundles_dir: MemoryPaths.bundles_dir, older_than_days: nil, now: Time.now, dry_run: false)
        entries = self.entries(bundles_dir: bundles_dir, now: now)
        if older_than_days
          cutoff = now - older_than_days.to_i * 86_400
          entries = entries.select { |e| e.time < cutoff }
        end
        return entries if dry_run

        entries.each do |e|
          FileUtils.rm_rf(e.path)
        end
        entries
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

      # Class methods below.

      def self.real_dir?(path)
        File.directory?(path) && !File.symlink?(path)
      end

      def self.entry_for(trash_dir, name, now)
        path = File.join(trash_dir, name)
        time = parse_timestamp(name) || File.mtime(path)
        files, bytes = count_files(path)
        Entry.new(name: name, path: path, time: time, files: files, bytes: bytes)
      end

      # Extracts a Time from "bundle-YYYYmmdd-HHMMSS" or "bundle-YYYYmmdd-HHMMSS-2".
      # Returns nil if the pattern doesn't match.
      TIMESTAMP_RE = /\A.*?-(\d{8})-(\d{6})(?:-\d+)?\z/

      def self.parse_timestamp(name)
        m = name.match(TIMESTAMP_RE)
        return nil unless m

        begin
          Time.strptime("#{m[1]}-#{m[2]}", "%Y%m%d-%H%M%S")
        rescue ArgumentError
          nil
        end
      end

      # Recursively counts files and sums their sizes.
      def self.count_files(dir)
        files = 0
        bytes = 0
        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |f|
          next if File.directory?(f)

          files += 1
          bytes += File.size(f) rescue 0
        end
        [files, bytes]
      end
    end
  end
end
