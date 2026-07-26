
# frozen_string_literal: true

require "fileutils"
require "digest"

module Samagotchi
  module Tools
    SYSTEM_MEMORIES_DIR = File.join(Dir.home, ".config", "samagotchi", "memories")
    PROJECT_MEMORIES_DIR = File.join(
      SYSTEM_MEMORIES_DIR,
      "projects",
      "#{File.basename(Dir.pwd)}_#{Digest::MD5.hexdigest(Dir.pwd)[0..7]}"
    )
    MEMORY_INDEX = "index"
    VALID_SCOPES = %w[project system].freeze

    # Reads a memory entry from scoped memory directories.
    # When scope is omitted, reads from project first and falls back to system.
    # Usage: call("entry_name", scope: "project"|"system"|nil)
    class MemoryRead
      NAME        = "memory_read"
      DESCRIPTION = 'Read a memory entry (MD file) from scoped memories. ' \
                    'Pass name without extension and optional scope (project|system). ' \
                    "When scope is omitted, read falls back from project to system."

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(entry_name, scope: nil)
        entry_name = entry_name.to_s.strip
        scope = normalize_scope(scope)

        if entry_name.empty?
          return scoped_index(scope) if scope

          project = scoped_index("project")
          system = scoped_index("system")
          return [
            "Project memories:",
            project,
            "",
            "System memories:",
            system
          ].join("\n")
        end

        scopes = scope ? [scope] : %w[project system]
        scopes.each do |resolved_scope|
          path = memory_path(entry_name, resolved_scope)
          return File.read(path) if File.exist?(path)
        end

        "Error: memory not found: #{entry_name}"
      rescue Errno::ENOENT
        "Error: memory not found: #{entry_name}"
      rescue => e
        "Error: #{e.message}"
      end

      def self.normalize_scope(scope)
        value = scope.to_s.strip
        return nil if value.empty?
        return value if VALID_SCOPES.include?(value)

        raise ArgumentError, "invalid scope '#{scope}', expected one of: #{VALID_SCOPES.join(', ')}"
      end

      def self.scoped_index(scope)
        dir = memories_dir(scope)
        index_path = File.join(dir, "#{MEMORY_INDEX}.md")
        return File.read(index_path) if File.exist?(index_path)

        files = Dir.glob(File.join(dir, "*.md")).sort
        return "No memories stored yet." if files.empty?

        "Stored memories (no index yet):\n" + files.map { |f| File.basename(f, ".md") }.join("\n")
      end

      def self.memory_path(entry_name, scope)
        File.join(memories_dir(scope), "#{entry_name}.md")
      end

      def self.memories_dir(scope)
        scope == "project" ? PROJECT_MEMORIES_DIR : SYSTEM_MEMORIES_DIR
      end
    end

    # Writes or updates a memory entry in a scoped memories directory.
    # Scope is required and must be one of: project, system.
    # Usage: call(content, path: "entry_name", scope: "project"|"system")
    class MemoryWrite
      NAME        = "memory_write"
      DESCRIPTION = 'Write or update a memory entry (MD file) in scoped memories. ' \
                    'Provide name via path and required scope (project|system).'

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(content, path:, scope:)
        entry_name = path.to_s.strip
        body = content.to_s
        return "Error: entry name is required" if entry_name.empty?
        return "Error: scope is required" if scope.to_s.strip.empty?
        return "Error: content is required" if body.empty?
        resolved_scope = MemoryRead.normalize_scope(scope)

        dir = MemoryRead.memories_dir(resolved_scope)
        FileUtils.mkdir_p(dir)
        file_path = File.join(dir, "#{entry_name}.md")
        File.write(file_path, body)
        "Memory '#{entry_name}' saved to #{resolved_scope} scope (#{body.bytesize} bytes)."
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
