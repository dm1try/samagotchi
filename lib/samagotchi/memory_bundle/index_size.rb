# frozen_string_literal: true

require_relative "../config"
require_relative "../tools/memory"
require_relative "../model_notes"

module Samagotchi
  module MemoryBundle
    # The size of one scope's memory index as a prompt carries it: every
    # session's system prompt holds both indexes in full, so their size is
    # paid on every request. tokens is the estimate ContextStatus uses
    # (characters / context.chars_per_token, rounded up), lines the
    # non-blank lines, bytes the UTF-8 size.
    #
    # memory_write and write/edit on a memory compare the size before and
    # after a write against memory.index_warn_tokens (#crossing_note);
    # chi self shows it (#summary), and a session's figure comes from the
    # index text its prompt holds (SystemPrompt).
    IndexSize = Data.define(:scope, :bytes, :lines, :tokens) do
      # @param text [String, nil] the index text
      # @param chars_per_token [Float]
      # @return [IndexSize]
      def self.of_text(scope, text, chars_per_token: self.chars_per_token)
        text = text.to_s
        new(scope: scope.to_s, bytes: text.bytesize, lines: text.each_line.count { |line| !line.strip.empty? },
            tokens: (text.length / chars_per_token).ceil)
      end

      # +scope+'s index as the prompt carries it before a session's own
      # filters (mutes): index.md, or the file listing without one, minus
      # the model notes' lines (ModelNotes.filter_index).
      # @param env [Hash] the XDG env the memories dir resolves from
      # @return [IndexSize]
      def self.of_scope(scope, chars_per_token: self.chars_per_token, env: ENV)
        text = Tools::MemoryRead.scoped_index(scope, env: env)
        of_text(scope, ModelNotes.filter_index(text, scope, env: env), chars_per_token: chars_per_token)
      end

      # of_scope, or nil when the index can't be read (a write's measure
      # must never fail the write).
      def self.measure(scope)
        of_scope(scope)
      rescue StandardError
        nil
      end

      # context.chars_per_token, 4.0 when it isn't positive.
      def self.chars_per_token
        value = Config.get("context.chars_per_token").to_f
        value.positive? ? value : 4.0
      rescue StandardError
        4.0
      end

      # memory.index_warn_tokens: the tokens one scope's index may hold
      # before a write that crosses it gets a note; 0 turns the note off.
      def self.warn_limit
        Config.get("memory.index_warn_tokens").to_i
      rescue StandardError
        0
      end

      # The note a write gets when it took the index from at or under
      # +limit+ to over it, nil otherwise: once per crossing, so a write
      # while the index is already over gets none and the note doesn't
      # start a loop of small tightenings. Sessions sharing the dir measure
      # on their own (before and after aren't one locked step), so writes
      # in parallel sessions racing over the limit may each get it.
      # @param before [IndexSize, nil]
      # @param after [IndexSize, nil]
      # @return [String, nil]
      def self.crossing_note(before, after, limit = warn_limit)
        return nil unless before && after && after.over?(limit) && !before.over?(limit)

        "Note: the #{after.scope} memory index is now ~#{after.tokens} tokens (over memory.index_warn_tokens " \
          "#{limit}) and is sent with every prompt. When you next have a moment, tighten long index " \
          "descriptions (memory_write with name, scope and description only). Don't remove or merge memories " \
          "unless the user asks."
      end

      # "450", "2.0k": a token count as the size readouts show it (the
      # web's ctx.js memoryIndexText too; spec/shared/labels_matrix.json).
      def self.count_text(tokens)
        value = tokens.to_i
        value >= 1000 ? "#{format("%.1f", (value / 100.0).round / 10.0)}k" : value.to_s
      end

      # Whether the index holds more than +limit+ tokens; a limit that
      # isn't positive is off.
      def over?(limit) = limit.to_i.positive? && tokens > limit.to_i

      # "system ~2.0k tokens (54 lines)", with ", over 2500" in the
      # parentheses when over +limit+: chi self's row.
      def summary(limit = 0)
        over = over?(limit) ? ", over #{limit}" : ""
        "#{scope} ~#{self.class.count_text(tokens)} tokens (#{lines} #{lines == 1 ? "line" : "lines"}#{over})"
      end

      # { tokens:, lines: }: the session's block (SessionMetrics).
      def figures = { tokens: tokens, lines: lines }
    end
  end
end
