# frozen_string_literal: true

require_relative "../config"
require_relative "index_size"
require_relative "index_sync"
require_relative "index_updater"
require_relative "../model_overlay"
require_relative "../tools/memory"

module Samagotchi
  module MemoryBundle
    # The size of one memory's text, which each memory_read of it pays
    # (memory_read is not cut by max_tool_output_chars). memory_write and
    # write/edit on a memory compare the size before and after a write
    # against memory.entry_warn_tokens (#crossing_note); `chi self` lists
    # the memories over it (SelfReport). tokens is the estimate IndexSize
    # uses (characters / context.chars_per_token, rounded up).
    #
    # A memory that didn't exist before a write counts as 0 tokens. Not
    # counted: the index, a model overlay, a model_notes_* memory (it has its
    # own warning).
    EntrySize = Data.define(:name, :scope, :tokens) do
      # @param text [String, nil] the memory's text
      # @return [EntrySize]
      def self.of_text(name, scope, text, chars_per_token: IndexSize.chars_per_token)
        new(name: name.to_s, scope: scope.to_s, tokens: (text.to_s.length / chars_per_token).ceil)
      end

      # Whether a memory of this name is sized at all (not the index, not a
      # model note).
      def self.counted?(name)
        name = name.to_s
        !name.casecmp?(IndexUpdater::MEMORY_INDEX) && !name.start_with?(Tools::MODEL_NOTES_PREFIX)
      end

      # The memory file at +path+ as it is now (0 tokens when it isn't
      # there), nil when it isn't a counted memory of a scope or
      # memory.entry_warn_tokens is off, or when it can't be measured (a
      # write's measure must never fail the write).
      # @return [EntrySize, nil]
      def self.measure_file(path)
        return nil unless warn_limit.positive?

        path = File.expand_path(path.to_s)
        scope = IndexSync.memory_scope(path)
        name = File.basename(path, ".md")
        return nil unless scope && counted?(name) && !ModelOverlay.overlay_file?(path)

        of_text(name, scope, File.file?(path) ? File.read(path, encoding: "UTF-8") : "")
      rescue StandardError
        nil
      end

      # The memories of +scope+ over +limit+ tokens, largest first: each
      # top-level *.md of its dir but the index, the overlays and the
      # model notes (hidden files, .bundles/ and archived/ are not in a
      # top-level glob). Nothing for a limit that isn't positive.
      # @param env [Hash] the XDG env the memories dir resolves from
      # @return [Array<EntrySize>]
      def self.over_limit(scope, limit: warn_limit, env: ENV)
        return [] unless limit.to_i.positive?

        Dir.glob(File.join(Tools::MemoryRead.memories_dir(scope, env: env), "*.md")).filter_map do |path|
          name = File.basename(path, ".md")
          next unless counted?(name) && File.file?(path) && !ModelOverlay.overlay_file?(path)

          size = of_text(name, scope, File.read(path, encoding: "UTF-8"))
          size if size.over?(limit)
        end.sort_by { |size| [-size.tokens, size.name] }
      end

      # memory.entry_warn_tokens: the tokens one memory may hold before a
      # write that crosses it gets a note; 0 turns the note off.
      def self.warn_limit
        Config.get("memory.entry_warn_tokens").to_i
      rescue StandardError
        0
      end

      # The note a write gets when it took the memory from at or under
      # +limit+ to over it, nil otherwise: once per crossing, as the
      # index's. Independent of memory.index_warn_tokens.
      # @param before [EntrySize, nil]
      # @param after [EntrySize, nil]
      # @return [String, nil]
      def self.crossing_note(before, after, limit = warn_limit)
        return nil unless before && after && after.over?(limit) && !before.over?(limit)

        "Note: memory '#{after.name}' is now ~#{after.tokens} tokens (over memory.entry_warn_tokens #{limit}), paid " \
          "on each read. When you next have a moment, tighten it; split out only parts that are read separately, " \
          "since each new memory adds an index line to every prompt. Don't remove or merge memories unless the " \
          "user asks."
      end

      # Whether the memory holds more than +limit+ tokens; a limit that
      # isn't positive is off.
      def over?(limit) = limit.to_i.positive? && tokens > limit.to_i
    end
  end
end
