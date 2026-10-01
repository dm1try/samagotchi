# frozen_string_literal: true
require "fileutils"
require "digest"
require_relative "../atomic_file"
require_relative "../memory_paths"
module Samagotchi
  module MemoryBundle
    # Updates the scoped index.md for a single entry, locked and atomically.
    # Used by Installer (P3) to keep index.md in sync.
    module IndexUpdater
      MEMORY_INDEX = "index"
      LOCK_FILE = ".index.lock"
      def self.update_index(scope, entry_name, byte_count, description = nil)
        index_path = index_path_for(scope)
        return true unless index_path
        locked_write(File.dirname(index_path)) do |content|
          new_line = managed_line(entry_name, scope, byte_count, description)
          next auto_index_header + "\n\n" + new_line + "\n" if content.nil? || content.strip.empty?

          pattern = managed_pattern(entry_name)
          if content.match?(pattern)
            existing_desc = extract_description(content[pattern].to_s)
            resolved_desc = description&.to_s&.strip || existing_desc
            new_line = managed_line(entry_name, scope, byte_count, resolved_desc)
            next content.sub(pattern) { new_line + $1 }
          end
          content.end_with?("\n") ? "#{content}#{new_line}\n" : "#{content}\n#{new_line}\n"
        end
        true
      end
      def self.managed_pattern(name)
        /^- \*\*#{Regexp.escape(name)}\*\*[ \t]*(?:[·•].*|:.*)?(\r?\n|\z)/
      end
      def self.remove_index(scope, entry_name)
        index_path = index_path_for(scope)
        return true unless index_path && File.exist?(index_path)
        locked_write(File.dirname(index_path)) do |content|
          pattern = managed_pattern(entry_name)
          next nil unless content&.match?(pattern)
          # Clean up extra blank lines: collapse 3+ newlines to 2
          content.gsub(pattern, "").gsub(/\n{3,}/, "\n\n")
        end
        true
      end
      # Read-modify-write of <dir>/index.md under an exclusive flock on a sidecar
      # <dir>/.index.lock, so sessions in several worktrees of one repository
      # (one shared project folder) don't drop each other's lines. Yields the
      # current content (nil when there is no index.md); the block returns the
      # new content, or nil to leave the file alone. The dir is not created here:
      # a missing one raises Errno::ENOENT, as the plain write did.
      def self.locked_write(dir)
        index_path = File.join(dir, "#{MEMORY_INDEX}.md")
        File.open(File.join(dir, LOCK_FILE), File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          content = File.exist?(index_path) ? File.read(index_path) : nil
          updated = yield content
          Samagotchi::AtomicFile.write(index_path, updated) unless updated.nil?
        end
      end
      def self.managed_line(name, scope, byte_count, description)
        line = "- **#{name}** · #{scope} · #{date_str} · #{byte_count}"
        desc = description&.to_s&.strip
        line += " — #{desc}" unless desc.to_s.empty?
        line
      end
      def self.extract_description(line)
        if line =~ /\s—\s(.*)\s*\z/
          $1
        elsif line =~ /:\s*(.*)\s*\z/
          $1
        end
      end
      def self.auto_index_header
        "# Memory Index\n\n" \
          "Managed entries below are auto-maintained by memory_write " \
          "(name, scope, last-written date, size). Free-form sections are preserved."
      end
      def self.date_str
        require "date"
        Date.today.iso8601
      end
      def self.index_path_for(scope)
        base_dir = MemoryPaths.scope_dir(scope.to_s.strip)
        base_dir && File.join(base_dir, "#{MEMORY_INDEX}.md")
      end
    end
  end
end