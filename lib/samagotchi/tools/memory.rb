# frozen_string_literal: true

require "fileutils"
require "digest"
require "date"
require_relative "../atomic_file"
require_relative "../memory_paths"

module Samagotchi
  module Tools
    MEMORY_INDEX = "index"
    VALID_SCOPES = %w[project system].freeze

    # Reads a memory entry from scoped memory directories.
    # When scope is omitted, reads from project first and falls back to system.
    # Usage: call("entry_name", scope: "project"|"system"|nil)
    class MemoryRead
      NAME        = "memory_read"

      def self.name        = NAME

      SEPARATOR = "\n\n---\n\n"

      # @param fallback_model_key [String, nil] read when +model_key+ has no overlay
      def self.call(entry_name, scope: nil, model_key: nil, fallback_model_key: nil)
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

        bad = names.find { |name| invalid_name?(name) }
        return invalid_name_error(bad) if bad

        resolved_scopes = scope ? [scope] : %w[project system]

        results = []
        missing = []

        names.each do |name|
          found = false
          resolved_scopes.each do |resolved_scope|
            path = memory_path(name, resolved_scope)
            next unless File.exist?(path)

            body = File.read(path, encoding: "UTF-8")
            # Append model-specific overlay if key is provided and overlay exists.
            [model_key, fallback_model_key].compact.each do |key|
              overlay_path = ModelOverlay.overlay_path_for(name, key, resolved_scope)
              next unless overlay_path && File.exist?(overlay_path)

              body += SEPARATOR + "Model-specific guidance (#{key}):\n" + File.read(overlay_path, encoding: "UTF-8")
              break
            end
            results << body
            found = true
            break
          end
          missing << name unless found
        end

        if results.empty? && !missing.empty?
          "Error: memory not found: #{missing.join(", ")}"
        elsif missing.empty?
          results.join(SEPARATOR)
        else
          results.join(SEPARATOR) + SEPARATOR + "Error: memory not found: #{missing.join(", ")}"
        end
      rescue Errno::ENOENT => e
        "Error: #{e.message}"
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # A memory is a flat file in its scope dir: a name with a path in it
      # ("../../x") would read or write outside the memories.
      def self.invalid_name?(name)
        name.include?("/") || name.include?("\\") || name.include?("..")
      end

      def self.invalid_name_error(name)
        "Error: invalid memory name '#{name}': use a plain name (no /, \\ or ..)"
      end

      def self.parse_names(entry_name)
        entry_name.split(",").map(&:strip).reject(&:empty?)
      end

      def self.normalize_scope(scope)
        value = scope.to_s.strip
        return nil if value.empty?
        return value if VALID_SCOPES.include?(value)

        raise ArgumentError, "invalid scope '#{scope}', expected one of: #{VALID_SCOPES.join(", ")}"
      end

      def self.scoped_index(scope)
        dir = memories_dir(scope)
        index_path = File.join(dir, "#{MEMORY_INDEX}.md")
        return File.read(index_path, encoding: "UTF-8") if File.exist?(index_path)

        files = Dir.glob(File.join(dir, "*.md")).sort
        return "No memories stored yet." if files.empty?

        "Stored memories (no index yet):\n" + files.map { |f| File.basename(f, ".md") }.join("\n")
      end

      def self.memory_path(entry_name, scope)
        File.join(memories_dir(scope), "#{entry_name}.md")
      end

      def self.memories_dir(scope, env: ENV)
        MemoryPaths.scope_dir(scope == "project" ? "project" : "system", env: env)
      end
    end

    # Writes or updates a memory entry in a scoped memories directory.
    # Scope is required and must be one of: project, system.
    # Optional `description` is appended to the managed index line when supplied.
    # Passing path: "index" writes index.md verbatim (no index maintenance).
    # Usage: call(content, path: "entry_name", scope: "project"|"system", description: "…")
    class MemoryWrite
      NAME        = "memory_write"

      def self.name        = NAME

      # A line is "managed for entry `name`" only when the bolded token exactly
      # equals the entry name, followed by end-of-line, `:`, or a middle dot.
      # This catches both the new ` · ` format and legacy `- **name**: desc`
      # lines so legacy entries upgrade in place, while safely ignoring free-form
      # prose such as `- **notes are important**`.
      def self.managed_pattern(name)
        /^- \*\*#{Regexp.escape(name)}\*\*[ \t]*(?:[·•].*|:.*)?(\r?\n|\z)/
      end

      # The longest description an index line takes: the line lands in
      # every session's prompt for the repo.
      DESCRIPTION_LIMIT = 200

      def self.call(content, path:, scope:, description: nil, current_model_only: false, model_key: nil)
        entry_name = path.to_s.strip
        body = content.to_s
        return "Error: entry name is required" if entry_name.empty?
        return MemoryRead.invalid_name_error(entry_name) if MemoryRead.invalid_name?(entry_name)
        return "Error: scope is required" if scope.to_s.strip.empty?

        description = normalize_description(description)
        if description && description.length > DESCRIPTION_LIMIT
          return "Error: description is #{description.length} characters; the limit is #{DESCRIPTION_LIMIT} " \
                 "(one line: what the memory is for)"
        end
        if body.empty?
          return "Error: content is required (or pass only description to change the index line)" unless description

          return update_description(entry_name, scope, description, current_model_only)
        end

        resolved_scope = MemoryRead.normalize_scope(scope)

        if current_model_only
          return "Error: model key is required for current_model_only writes" if model_key.nil? || model_key.to_s.strip.empty?
          return "Error: invalid model key for current_model_only writes" unless model_key.to_s.match?(/\A[a-z0-9-]+\z/)
          return "Error: current_model_only is incompatible with the index entry" if entry_name == MEMORY_INDEX
        end

        dir = MemoryRead.memories_dir(resolved_scope)
        FileUtils.mkdir_p(dir)
        require_relative "../memory_bundle/index_updater"

        if current_model_only && model_key
          # Overlays are only read through their base entry (same scope), so an
          # overlay without one would never load.
          unless File.exist?(File.join(dir, "#{entry_name}.md"))
            return "Error: no base entry '#{entry_name}' in #{resolved_scope} scope; a model overlay is only " \
                   "loaded together with its base. Write the base entry first (without current_model_only), " \
                   "then write the overlay."
          end

          file_path = File.join(dir, "#{entry_name}.#{model_key}.md")
          Samagotchi::AtomicFile.write(file_path, body)
          bytes = body.bytesize
          return "Model overlay '#{entry_name}' for #{model_key} saved to #{resolved_scope} scope (#{bytes} bytes). File written: #{file_path}"
        end

        file_path = File.join(dir, "#{entry_name}.md")
        if entry_name == MEMORY_INDEX
          Samagotchi::MemoryBundle::IndexUpdater.locked_write(dir) { body }
        else
          Samagotchi::AtomicFile.write(file_path, body)
        end
        bytes = body.bytesize
        message = "Memory '#{entry_name}' saved to #{resolved_scope} scope (#{bytes} bytes). File written: #{file_path}"

        # The verbatim "write to index.md" behavior (path: "index") must not
        # trigger upsert logic.
        if !(entry_name == MEMORY_INDEX) && manage_index(resolved_scope, entry_name, bytes, description)
          message += " Index line refreshed automatically."
        end

        message
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # A description as the index line takes it: whitespace (newlines too)
      # collapsed to single spaces; nil when blank, which keeps the stored one.
      def self.normalize_description(description)
        text = description.to_s.gsub(/\s+/, " ").strip
        text.empty? ? nil : text
      end

      # The description-only form: name, scope and description, no content.
      # Rewrites that entry's index line (size and date too) and leaves its
      # file alone, so a status kept in the description costs no rewrite of
      # the body.
      def self.update_description(entry_name, scope, description, current_model_only)
        return "Error: the index has no index line of its own; pass content to write it" if entry_name == MEMORY_INDEX
        if current_model_only
          return "Error: a model overlay has no index line; pass content to write the overlay, or drop " \
                 "current_model_only to change the base entry's description"
        end

        resolved_scope = MemoryRead.normalize_scope(scope)
        file_path = File.join(MemoryRead.memories_dir(resolved_scope), "#{entry_name}.md")
        return "Error: no memory '#{entry_name}' in #{resolved_scope} scope; pass content to create it" unless File.file?(file_path)

        manage_index(resolved_scope, entry_name, File.size(file_path), description)
        "Memory '#{entry_name}' description updated in #{resolved_scope} scope (file unchanged)."
      end

      # Adds or refreshes a single managed line for `entry_name` in the given
      # scope's index.md, preserving every other byte byte-for-byte.
      # Delegates to IndexUpdater to maintain a single source of truth.
      # Returns true when an entry was written (i.e. the index was managed).
      def self.manage_index(scope, entry_name, byte_count, description = nil)
        require_relative "../memory_bundle/index_updater"
        Samagotchi::MemoryBundle::IndexUpdater.update_index(scope, entry_name, byte_count, description)
      end

      def self.managed_line(name, scope, byte_count, description)
        Samagotchi::MemoryBundle::IndexUpdater.managed_line(name, scope, byte_count, description)
      end

      # Extracts the human description from an existing managed line so that a
      # legacy `- **name**: desc` or a new-format line with a description keeps
      # its description when the entry is updated without a new one.
      def self.extract_description(line)
        Samagotchi::MemoryBundle::IndexUpdater.extract_description(line)
      end

      def self.auto_index_header
        Samagotchi::MemoryBundle::IndexUpdater.auto_index_header
      end

      def self.date_str
        Samagotchi::MemoryBundle::IndexUpdater.date_str
      end

      def self.index_path_for(scope)
        File.join(MemoryRead.memories_dir(scope), "#{MEMORY_INDEX}.md")
      end
    end
  end
end

# model_overlay.rb requires this file, and MemoryRead only needs ModelOverlay
# at call time, so autoload it instead of a (circular) require.
module Samagotchi
  autoload :ModelOverlay, File.expand_path("../model_overlay", __dir__)
end
