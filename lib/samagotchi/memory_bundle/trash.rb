# frozen_string_literal: true

require "fileutils"
require_relative "../memory_paths"
require_relative "provenance"

module Samagotchi
  module MemoryBundle
    # Where a bundle operation puts the memory files it takes away
    # (uninstall, an upgrade's dropped file): moved, never deleted, into
    # <system memories>/.bundles/.trash/<bundle>-<YYYYmmdd-HHMMSS>/, one dir
    # per operation (-2, -3… when one already has that name). A file about to
    # be overwritten is copied there instead (#copy). A dot dir, so
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
          cutoff = now - (older_than_days.to_i * 86_400)
          entries = entries.select { |e| e.time < cutoff }
        end
        return entries if dry_run

        entries.each do |e|
          FileUtils.rm_rf(e.path)
        end
        entries
      end

      # The one refusal for a file system error while files are being saved and
      # replaced. Every save comes before its removal, so an edit is where it
      # was or in the trash; a retry finds what this run already placed.
      def self.failure_message(error)
        "#{error.message}: nothing was lost (your edits are in place or in the trash); fix that and run the command again"
      end

      # The dir, once a file was moved or copied (nil before).
      attr_reader :dir

      # What #copy saved, each by its name in the dir.
      attr_reader :copied

      def initialize(name, now: Time.now, bundles_dir: MemoryPaths.bundles_dir)
        @name = name.to_s
        @now = now
        @bundles_dir = bundles_dir
        @dir = nil
        @copied = []
      end

      # Moves +path+ into the trash dir (created on the first call).
      # @return [String] the file's new path
      def move(path)
        dest = File.join(ensure_dir, File.basename(path))
        FileUtils.mv(path, dest)
        dest
      end

      # Copies +path+ (through a link, its mode kept) into the trash dir,
      # the original staying: for a file about to be overwritten.
      # @param as [String] its name there; "hooks/x" keeps a subfolder, so
      #   hooks/x and scripts/x don't collide
      # @return [String] the copy's path
      def copy(path, as: File.basename(path))
        dest = File.join(ensure_dir, as)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(path, dest, preserve: true)
        @copied << as
        dest
      end

      # Copies the file at +path+ as +as+ before it is replaced or removed, when
      # that would lose something: its bytes are neither what the record says
      # was installed (no sha recorded: unknown, so it counts as edited) nor
      # +incoming+'s. A link (a dev install's) points at its source, which
      # nothing here touches.
      def copy_edit(path, as:, recorded: nil, incoming: nil)
        return if File.symlink?(path) || !File.file?(path)
        return if incoming && File.file?(incoming) && FileUtils.identical?(incoming, path)
        return if !Provenance.recorded_sha(recorded).empty? && Provenance.sha_matches?(path, recorded)

        copy(path, as: as)
      end

      # copy_edit for every file under +dir+, which is about to go, at any depth
      # (kept as <label>/<its path in dir>). A linked dir isn't followed.
      # @param recorded [Hash, nil] path in dir => its recorded sha256
      # @param incoming [Hash] path in dir => the source replacing it
      def copy_edits(dir, label, recorded = nil, incoming = {})
        return if File.symlink?(dir) || !File.directory?(dir)

        Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.each do |file|
          copy_edit(File.join(dir, file), as: "#{label}/#{file}", recorded: recorded&.[](file), incoming: incoming[file])
        end
      end

      # What #copy saved, said once (nil: nothing).
      def copy_line
        "Copied to the trash first: #{@copied.join(", ")} (#{@dir})" unless @copied.empty?
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

      def self.entry_for(trash_dir, name, _now)
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

      private_class_method :real_dir?, :entry_for, :parse_timestamp, :count_files
    end
  end
end
