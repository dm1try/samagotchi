# frozen_string_literal: true

require "fileutils"

module Samagotchi
  module Tools
    MEMORIES_DIR = "memories"

    # Reads a memory entry from the memories directory.
    # If no name is given (or the content is blank), lists all available memories.
    # Usage: <tool name="memory_read">entry_name</tool>
    class MemoryRead
      NAME        = "memory_read"
      DESCRIPTION = 'Read a memory entry (MD file) from the memories directory. ' \
                    'Pass entry name without extension: <tool name="memory_read">entry_name</tool>. ' \
                    "Leave blank to list all stored memories."

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(entry_name)
        entry_name = entry_name.to_s.strip
        dir = MEMORIES_DIR

        if entry_name.empty?
          files = Dir.glob(File.join(dir, "*.md")).sort
          return "No memories stored yet." if files.empty?

          return "Stored memories:\n" + files.map { |f| File.basename(f, ".md") }.join("\n")
        end

        path = File.join(dir, "#{entry_name}.md")
        File.read(path)
      rescue Errno::ENOENT
        "Error: memory not found: #{entry_name}"
      rescue => e
        "Error: #{e.message}"
      end
    end

    # Writes or updates a memory entry in the memories directory.
    # Usage: <tool name="memory_write" path="entry_name">content</tool>
    class MemoryWrite
      NAME        = "memory_write"
      DESCRIPTION = 'Write or update a memory entry (MD file) in the memories directory. ' \
                    'Use path attribute for the entry name: ' \
                    '<tool name="memory_write" path="entry_name">content</tool>'

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(content, path:)
        entry_name = path.to_s.strip
        return "Error: entry name is required" if entry_name.empty?

        dir = MEMORIES_DIR
        FileUtils.mkdir_p(dir)
        file_path = File.join(dir, "#{entry_name}.md")
        File.write(file_path, content)
        "Memory '#{entry_name}' saved (#{content.bytesize} bytes)."
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
