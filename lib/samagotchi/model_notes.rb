# frozen_string_literal: true

require "digest"
require_relative "log"
require_relative "model_match"
require_relative "model_overlay"
require_relative "memory_paths"
require_relative "muted_memories"
require_relative "tools/memory"
require_relative "guardrails/model_size"

module Samagotchi
  # Model notes: memories named `model_notes_<name>` whose first line says
  # which models they are for, in ModelMatch's grammar:
  #
  #   models: deepseek-*|*deepseek-v4*
  #   Working habits for this model: ...
  #
  # Every note matching the session's model is loaded into the system
  # prompt (SystemPrompt#model_notes_section, after identity), stacked: the
  # system scope's, then the project's, by name within a scope. Notes add
  # habits; none overrides another. The body is read through memory_read,
  # so a note's own model overlays are appended as for any memory; the
  # models: line is left out. Their index lines are left out of the
  # prompt's indexes (#filter_index): the body is already there.
  module ModelNotes
    PREFIX = Tools::MODEL_NOTES_PREFIX
    SCOPES = %w[system project].freeze
    # A note over this, or all of them over TOTAL_LIMIT, still loads but
    # warns once: they cost every request.
    NOTE_LIMIT = 1_500
    TOTAL_LIMIT = 3_000

    # name: the memory name; scope: "system" or "project"; body: what the
    # prompt carries (overlays appended, the models: line dropped); chars:
    # its length; digest: a short SHA-256 of it.
    Note = Data.define(:name, :scope, :body, :chars, :digest)

    @warned = Set.new
    @warn_mutex = Mutex.new

    module_function

    # The notes for a model.
    # @param name [String, nil] the bare model id (no host prefix)
    # @param key [String, nil] its model key (ModelOverlay.key_for)
    # @param fallback_key [String, nil] the overlay key read when +key+ has
    #   none (SystemPrompt::ModelIdentity#fallback_key)
    # @param muted [Array<String>] the session's muted names (MutedMemories)
    # @param small [#call, nil] → whether the model is a small one; nil:
    #   guardrails.small_models (Guardrails::ModelSize)
    # @return [Array<Note>]
    def for(name:, key:, fallback_key: nil, muted: [], small: nil)
      return [] if name.nil? || name.to_s.strip.empty?

      small ||= -> { Guardrails::ModelSize.small?(name, key) }
      small_once = memo(small)
      seen = Set.new
      notes = SCOPES.flat_map do |scope|
        files(scope).filter_map do |path|
          next unless seen.add?(File.expand_path(path))

          note_at(path, scope, name: name, key: key, fallback_key: fallback_key, muted: muted, small: small_once)
        end
      end
      warn_sizes(notes)
      notes
    end

    # +text+ (+scope+'s memory index) without the lines naming a model note
    # that loads for some model (its file in +scope+ has a `models:` line);
    # the same object when it names none. A `model_notes_*` memory that
    # isn't one keeps its line, so it doesn't vanish.
    def filter_index(text, scope)
      return text if text.nil? || !text.include?(PREFIX)

      dir = MemoryPaths.scope_dir(scope)
      names = files_in(dir).map { |path| File.basename(path) }
      text.each_line.reject do |line|
        name = MutedMemories.index_line_name(line).to_s
        name.start_with?(PREFIX) && !name.include?(".") && names.include?("#{name}.md") &&
          note_file?(File.join(dir, "#{name}.md"))
      end.join
    end

    # Whether +path+ is a model note's file: it has a models: first line.
    def note_file?(path)
      File.file?(path) && !ModelMatch.models_line(File.open(path, encoding: "UTF-8", &:gets)).nil?
    rescue StandardError
      false
    end

    # Forgets which warnings were given (specs).
    def reset_warnings!
      @warn_mutex.synchronize { @warned.clear }
    end

    def files(scope) = files_in(MemoryPaths.scope_dir(scope))

    # The `model_notes_*.md` files in +dir+, by their names on disk: the
    # prefix exactly as written (a case-insensitive disk's glob matches
    # MODEL_NOTES_x.md too, which the guardrails would not see as a note).
    def files_in(dir)
      Dir.glob(File.join(dir, "#{PREFIX}*.md")).select { |path| File.basename(path).start_with?(PREFIX) }.sort
    rescue StandardError
      []
    end

    def note_at(path, scope, name:, key:, fallback_key:, muted:, small:)
      stem = File.basename(path, ".md")
      return nil if dotted?(path, stem)
      return nil if MutedMemories.muted?(stem, muted)

      entries = models_of(path)
      return nil unless entries
      return nil unless ModelMatch.match?(entries, name: name, key: key, small: small)

      body = File.read(path, encoding: "UTF-8").sub(/\A[^\n]*\n?/, "").strip
      return nil if body.empty?

      body = with_overlay(body, stem, scope, [key, fallback_key])

      Note.new(name: stem, scope: scope, body: body, chars: body.length, digest: Digest::SHA256.hexdigest(body)[0, 12])
    rescue StandardError
      nil
    end

    # The note's model overlay appended as memory_read appends one: the
    # key's, else the fallback key's. The file is read by its own path, not
    # by name through memory_read (whose names are comma lists).
    def with_overlay(body, stem, scope, keys)
      keys.compact.each do |overlay_key|
        overlay = ModelOverlay.overlay_path_for(stem, overlay_key, scope)
        next unless overlay && File.file?(overlay)

        return "#{body}#{Tools::MemoryRead::SEPARATOR}Model-specific guidance (#{overlay_key}):\n" \
               "#{File.read(overlay, encoding: "UTF-8").strip}"
      end
      body
    end

    # A model overlay of a note (`model_notes_a.<key>.md`) is read with
    # its note; any other dotted name is skipped with a warning (memory_write
    # refuses it: next to a base it would read as an overlay).
    def dotted?(path, stem)
      return false unless stem.include?(".")

      unless ModelOverlay.overlay_file?(path)
        warn_once("model_note_skipped", "Warning: model note #{path} skipped: a model note's name has no dot " \
                                        "(rename it, e.g. #{Tools::MemoryWrite.undotted(stem)}.md)", path)
      end
      true
    end

    # The entries of the file's `models:` first line; nil (warned once)
    # without one.
    def models_of(path)
      entries = ModelMatch.models_line(File.open(path, encoding: "UTF-8", &:gets))
      return entries if entries

      warn_once("model_note_skipped", "Warning: model note #{path} skipped: its first line must be " \
                                      "`models: <glob>|small|…`", path)
      nil
    end

    def warn_sizes(notes)
      notes.each do |note|
        next unless note.chars > NOTE_LIMIT

        warn_once("model_notes_large", "Warning: model note #{note.name} (#{note.scope}) is #{note.chars} chars, over " \
                                       "#{NOTE_LIMIT}: it is sent with every request", note.name)
      end
      total = notes.sum(&:chars)
      return unless total > TOTAL_LIMIT

      warn_once("model_notes_large", "Warning: the model notes for this model are #{total} chars, over #{TOTAL_LIMIT}: " \
                                     "they are sent with every request", notes.map(&:name).join(","))
    end

    # Once per message for the process (a prompt is built again on a
    # model switch, another thinking level, changed tools).
    def warn_once(event, echo, memory)
      first = @warn_mutex.synchronize { @warned.add?(echo) }
      Log.warn(:memory, event, echo: echo, memory: memory) if first
    end

    def memo(callable)
      value = nil
      known = false
      lambda do
        unless known
          value = callable.call
          known = true
        end
        value
      end
    end

    private_class_method :note_file?, :files, :files_in, :note_at, :with_overlay, :dotted?, :models_of, :warn_sizes, :warn_once, :memo
  end
end
