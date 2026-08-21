
# frozen_string_literal: true

require "fileutils"
require "digest"
require "date"

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
                    "When scope is omitted, read falls back from project to system. " \
                    'Multiple comma-separated names (e.g. "one, two") read all matched entries ' \
                    'concatenated with a `---` separator.'

      def self.name        = NAME
      def self.description = DESCRIPTION

      SEPARATOR = "\n\n---\n\n"

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

        names = parse_names(entry_name)

        if names.empty?
          return "Error: no memory names provided"
        end

        resolved_scopes = scope ? [scope] : %w[project system]

        results = []
        missing = []

        names.each do |name|
          found = false
          resolved_scopes.each do |resolved_scope|
            path = memory_path(name, resolved_scope)
            if File.exist?(path)
              results << File.read(path)
              found = true
              break
            end
          end
          missing << name unless found
        end

        if results.empty? && !missing.empty?
          "Error: memory not found: #{missing.join(', ')}"
        elsif missing.empty?
          results.join(SEPARATOR)
        else
          results.join(SEPARATOR) + SEPARATOR + "Error: memory not found: #{missing.join(', ')}"
        end
      rescue Errno::ENOENT => e
        "Error: #{e.message}"
      rescue => e
        "Error: #{e.message}"
      end

      def self.parse_names(entry_name)
        entry_name.split(",").map(&:strip).reject(&:empty?)
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
    # Optional `description` is appended to the managed index line when supplied.
    # Passing path: "index" writes index.md verbatim (no index maintenance).
    # Usage: call(content, path: "entry_name", scope: "project"|"system", description: "…")
    class MemoryWrite
      NAME        = "memory_write"
      DESCRIPTION = 'Write or update a memory entry (MD file) in scoped memories. ' \
                    'Provide the entry name (via the `name` parameter) and required scope (project|system). ' \
                    'Optional description is appended to the managed index line.'

      def self.name        = NAME
      def self.description = DESCRIPTION

      # A line is "managed for entry `name`" only when the bolded token exactly
      # equals the entry name, followed by end-of-line, `:`, or a middle dot.
      # This catches both the new ` · ` format and legacy `- **name**: desc`
      # lines so legacy entries upgrade in place, while safely ignoring free-form
      # prose such as `- **notes are important**`.
      def self.managed_pattern(name)
        /^- \*\*#{Regexp.escape(name)}\*\*[ \t]*(?:[·•].*|:.*)?(\r?\n|\z)/
      end

      def self.call(content, path:, scope:, description: nil)
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
        bytes = body.bytesize
        message = "Memory '#{entry_name}' saved to #{resolved_scope} scope (#{bytes} bytes)."

        # The verbatim "write to index.md" behavior (path: "index") must not
        # trigger upsert logic.
        unless entry_name == MEMORY_INDEX
          index_path = self.index_path_for(resolved_scope)
          if manage_index(resolved_scope, entry_name, bytes, description)
            message += " Index updated: #{index_path}"
          end
        end

        message
      rescue => e
        "Error: #{e.message}"
      end

      # Adds or refreshes a single managed line for `entry_name` in the given
      # scope's index.md, preserving every other byte byte-for-byte.
      # Returns true when an entry was written (i.e. the index was managed).
      def self.manage_index(scope, entry_name, byte_count, description)
        index_path = self.index_path_for(scope)
        new_line = self.managed_line(entry_name, scope, byte_count, description)
        content = File.exist?(index_path) ? File.read(index_path) : nil

        # New file (or blank existing file): create with a brief header.
        if content.nil? || content.strip.empty?
          File.write(index_path, "#{self.auto_index_header}\n\n#{new_line}\n")
          return true
        end

        pattern = self.managed_pattern(entry_name)

        # Upsert: replace the existing managed line for this entry in place.
        if content.match?(pattern)
          existing_description = self.extract_description(content[pattern].to_s)
          resolved_description =
            if description.to_s.strip.empty?
              existing_description
            else
              description
            end
          new_line = self.managed_line(entry_name, scope, byte_count, resolved_description)
          updated = content.sub(pattern) { new_line + $1 }
          File.write(index_path, updated)
          return true
        end

        # Append: add a new managed line, keeping the file newline-terminated.
        updated = if content.end_with?("\n")
                    "#{content}#{new_line}\n"
                  else
                    "#{content}\n#{new_line}\n"
                  end
        File.write(index_path, updated)
        true
      end

      def self.managed_line(name, scope, byte_count, description)
        line = "- **#{name}** · #{scope} · #{self.date_str} · #{byte_count}"
        desc = description.to_s.strip
        line += " — #{desc}" unless desc.empty?
        line
      end

      # Extracts the human description from an existing managed line so that a
      # legacy `- **name**: desc` or a new-format line with a description keeps
      # its description when the entry is updated without a new one.
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
        Date.today.iso8601
      end

      def self.index_path_for(scope)
        File.join(MemoryRead.memories_dir(scope), "#{MEMORY_INDEX}.md")
      end
    end
  end
end
