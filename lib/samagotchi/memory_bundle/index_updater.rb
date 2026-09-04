# frozen_string_literal: true
require "fileutils"
require "digest"
module Samagotchi
  module MemoryBundle
    # Atomically updates the scoped index.md for a single entry.
    # Used by Installer (P3) to keep index.md in sync.
    # Delegates to MemoryRead.memories_dir for test-isolated paths.
    module IndexUpdater
      MEMORY_INDEX = "index"
      def self.system_dir_override
        @system_dir_override
      end
      def self.system_dir_override=(val)
        @system_dir_override = val
      end
      def self.project_dir_base_override
        @project_dir_base_override
      end
      def self.project_dir_base_override=(val)
        @project_dir_base_override = val
      end
      def self.update_index(scope, entry_name, byte_count, description = nil)
        index_path = index_path_for(scope)
        return true unless index_path
        new_line = managed_line(entry_name, scope, byte_count, description)
        content = File.exist?(index_path) ? File.read(index_path) : nil
        if content.nil? || content.strip.empty?
          File.write(index_path, auto_index_header + "\n\n" + new_line + "\n")
          return true
        end
        pattern = managed_pattern(entry_name)
        if content.match?(pattern)
          existing_desc = extract_description(content[pattern].to_s)
          resolved_desc = description&.to_s&.strip || existing_desc
          new_line = managed_line(entry_name, scope, byte_count, resolved_desc)
          updated = content.sub(pattern) { new_line + $1 }
          File.write(index_path, updated)
          return true
        end
        updated = content.end_with?("\n") ? "#{content}#{new_line}\n" : "#{content}\n#{new_line}\n"
        File.write(index_path, updated)
        true
      end
      def self.managed_pattern(name)
        /^- \*\*#{Regexp.escape(name)}\*\*[ \t]*(?:[·•].*|:.*)?(\r?\n|\z)/
      end
      def self.remove_index(scope, entry_name)
        index_path = index_path_for(scope)
        return true unless index_path && File.exist?(index_path)
        content = File.read(index_path)
        pattern = managed_pattern(entry_name)
        return true unless content.match?(pattern)
        updated = content.gsub(pattern, "")
        # Clean up extra blank lines: collapse 3+ newlines to 2
        updated = updated.gsub(/\n{3,}/, "\n\n")
        File.write(index_path, updated)
        true
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
        normalized = scope.to_s.strip
        normalized = "system" if normalized.empty?
        base_dir = case normalized
                   when "system"
                     system_dir_override ||
                       (defined?(Samagotchi::Tools::SYSTEM_MEMORIES_DIR) ? Samagotchi::Tools::SYSTEM_MEMORIES_DIR : File.join(Dir.home, ".config", "samagotchi", "memories"))
                   when "project"
                     if project_dir_base_override
                       File.join(
                         project_dir_base_override,
                         "#{File.basename(Dir.pwd)}_#{Digest::MD5.hexdigest(Dir.pwd)[0..7]}"
                       )
                     else
                       (defined?(Samagotchi::Tools::PROJECT_MEMORIES_DIR) ? Samagotchi::Tools::PROJECT_MEMORIES_DIR : File.join(Dir.home, ".config", "samagotchi", "memories", "projects", "#{File.basename(Dir.pwd)}_#{Digest::MD5.hexdigest(Dir.pwd)[0..7]}"))
                     end
                   else
                     return nil
                   end
        File.join(base_dir, "#{MEMORY_INDEX}.md")
      end
    end
  end
end