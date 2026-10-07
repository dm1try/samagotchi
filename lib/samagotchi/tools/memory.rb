# frozen_string_literal: true

require "fileutils"
require "digest"
require "date"
require_relative "../atomic_file"
require_relative "../memory_paths"
require_relative "../model_match"

module Samagotchi
  module Tools
    MEMORY_INDEX = "index"
    VALID_SCOPES = %w[project system].freeze
    # Model notes (ModelNotes): `model_notes_<name>`, no dot in the name.
    MODEL_NOTES_PREFIX = "model_notes_"

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

      # @param remove [Boolean] move the entry (and its model overlays) into
      #   the bundle trash and drop its index line (#remove)
      def self.call(content, path:, scope:, description: nil, current_model_only: false, model_key: nil, remove: false)
        entry_name = path.to_s.strip
        body = content.to_s
        return "Error: entry name is required" if entry_name.empty?
        return MemoryRead.invalid_name_error(entry_name) if MemoryRead.invalid_name?(entry_name)
        return "Error: scope is required" if scope.to_s.strip.empty?

        if remove
          if !body.empty? || !description.to_s.strip.empty? || current_model_only
            return "Error: remove: true takes only name and scope (no content, description or current_model_only)"
          end

          return remove(entry_name, scope)
        end
        if entry_name.include?(",")
          return "Error: invalid memory name '#{entry_name}': no commas (memory_read reads a comma list of names); " \
                 "use '#{entry_name.tr(",", "_")}'"
        end
        return dotted_model_note_error(entry_name) if dotted_model_note?(entry_name)
        if (error = model_note_body_error(entry_name, body, current_model_only))
          return error
        end

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

      # A model note's name with a dot would read as a model overlay
      # (`<name>.<key>.md`) next to a note of the stem's name.
      def self.dotted_model_note?(name) = name.start_with?(MODEL_NOTES_PREFIX) && name.include?(".")

      def self.dotted_model_note_error(name)
        "Error: invalid model note name '#{name}': no dot after #{MODEL_NOTES_PREFIX} (a dotted name reads as a " \
          "model overlay); use '#{undotted(name)}'"
      end

      # +name+ with its dots made dashes, a trailing ".md" dropped first
      # (`model_notes_x.md` → `model_notes_x`).
      def self.undotted(name) = name.delete_suffix(".md").tr(".", "-")

      # A model note's content must start with its models: line, or the note
      # would never load (and its index line would hide it from no one). Its
      # model overlay (current_model_only) has none.
      def self.model_note_body_error(name, body, current_model_only)
        return nil unless name.start_with?(MODEL_NOTES_PREFIX) && !body.empty? && !current_model_only
        return nil if ModelMatch.models_line(body)

        first = body.each_line.first.to_s.strip
        first = "#{first[0, 60]}…" if first.length > 60
        "Error: model note '#{name}' needs a first line saying which models it is for, `models: <glob>|small|…` " \
          "(e.g. `models: deepseek-*|small`: globs on the model id or key, small per guardrails.small_models), " \
          "then the note; the first line is #{first.empty? ? "empty" : "`#{first}`"}. A memory that isn't a model " \
          "note needs a name without the #{MODEL_NOTES_PREFIX} prefix."
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

      # remove: true. Moves <name>.md and its model overlays into one
      # MemoryBundle::Trash dir (memory-<name>-<time>, which `chi bundle
      # trash` lists and empties) and drops the index line; a line whose
      # file is already gone is dropped alone. A memory a bundle owns (an
      # installed bundle's record lists it, or its line says "· from
      # <bundle>") is the uninstaller's, and the index isn't a memory.
      def self.remove(entry_name, scope)
        return "Error: the index can't be removed; it is kept up to date for you" if entry_name == MEMORY_INDEX

        require_relative "../memory_bundle/index_updater"
        require_relative "../memory_bundle/provenance"
        require_relative "../memory_bundle/trash"
        resolved_scope = MemoryRead.normalize_scope(scope)
        dir = MemoryRead.memories_dir(resolved_scope)
        index = File.join(dir, "#{MEMORY_INDEX}.md")
        index_text = File.file?(index) ? File.read(index, encoding: "UTF-8") : ""
        line = index_text[managed_pattern(entry_name)]
        file = File.join(dir, "#{entry_name}.md")

        owner = Samagotchi::MemoryBundle::Provenance.claimants("#{entry_name}.md", scope: resolved_scope).first ||
                (line && Samagotchi::MemoryBundle::IndexUpdater.extract_source(line))
        return "Error: memory '#{entry_name}' came from bundle #{owner}; `chi bundle uninstall #{owner}` removes it" if owner

        unless File.file?(file)
          return "Error: no memory '#{entry_name}' in #{resolved_scope} scope" unless line

          Samagotchi::MemoryBundle::IndexUpdater.remove_index(resolved_scope, entry_name)
          return "Memory '#{entry_name}' had no file in #{resolved_scope} scope; its dangling index line was dropped."
        end

        trash = Samagotchi::MemoryBundle::Trash.new("memory-#{entry_name}")
        ([file] + overlay_files(dir, entry_name, index_text)).each { |path| trash.move(path) }
        Samagotchi::MemoryBundle::IndexUpdater.remove_index(resolved_scope, entry_name)
        "Memory '#{entry_name}' removed from #{resolved_scope} scope: moved to #{trash.dir} " \
          "(`chi bundle trash` lists and empties it); index line dropped."
      end

      # The entry's model overlays: <name>.<key>.md with a key ModelOverlay
      # makes, unless that stem is a memory of its own (names may have dots:
      # handoff_x.v2 has an index line).
      def self.overlay_files(dir, entry_name, index_text)
        pattern = /\A#{Regexp.escape(entry_name)}\.([a-z0-9-]+)\.md\z/
        Dir.children(dir).sort.filter_map do |child|
          key = child[pattern, 1] or next
          next if index_text.match?(managed_pattern("#{entry_name}.#{key}"))

          path = File.join(dir, child)
          path if File.file?(path)
        end
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
