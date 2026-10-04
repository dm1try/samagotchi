# frozen_string_literal: true

require "monitor"
require_relative "line_reader"

module Samagotchi
  class TerminalUI
    # The REPL's input on a terminal: one LineReader keeps a prompt open for
    # the whole session, turns included, and this routes what it reads. A
    # line goes to a question waiting at the prompt (asked at ? ), to
    # the running turn when its handler takes it (steering), else to the
    # inbox the REPL loop takes its next line from.
    class ReplInput
      # @param prompt [#call] -> the prompt when no question waits
      # @param read [#call] (prompt, prefill) -> line (nil = Ctrl-D)
      # @param surface [Surface] the editor slot a dropped read leaves is
      #   cleared under its lock
      def initialize(prompt:, read:, surface:)
        @prompt = prompt
        @read = read
        @surface = surface
        @inbox = Thread::Queue.new
        # Lines a turn left over: they come before the inbox.
        @front = []
        @turn = nil
        @lock = Monitor.new
        @answers = nil
      end

      def start(prefill: nil)
        @reader = LineReader.new(self, prompt: method(:prompt_text), read: @read, prefill: prefill).start
        self
      end

      def open? = @reader&.alive? || false

      def stop
        @reader&.stop
        @surface.clear_slot(:editor)
      end

      # From the reader thread: [:line, text] or [:interrupt, info].
      def <<(item)
        @lock.synchronize do
          next @answers << item if @answers

          taken = @turn && item.first == :line && @turn.call(item.last)
          # Not now: the line goes back into the prompt.
          next @reader&.prefill_next(item.last) if taken == :back
          next if taken

          @inbox << item
        end
        self
      end

      # @return [Array, nil] the next item, nil after +timeout+ seconds
      def pop(timeout:)
        @lock.synchronize { return @front.shift unless @front.empty? }
        @inbox.pop(timeout: timeout)
      end

      # While a turn runs, +handler+ (line -> truthy when it took the line,
      # :back to put it back into the prompt) sees each line first. Once it ends, +leftovers+ (-> lines it took that the
      # turn never merged) come next, in order, before anything in the inbox.
      def during_turn(handler, leftovers:)
        @lock.synchronize { @turn = handler }
        yield
      ensure
        @lock.synchronize do
          @turn = nil
          @front.concat(Array(leftovers.call).map { |line| [:line, line] })
        end
      end

      def prompt_text
        @lock.synchronize { @answers ? @choice_prompt : @prompt.call }
      end

      # Start the open read again when its prompt changed (a continue offer
      # came or went); what was typed is kept.
      def sync_prompt
        return unless open?

        with_surface_lock do
          next if @reader.current == prompt_text

          @surface.clear_slot(:editor)
          @reader.reprompt(keep_text: true)
        end
      end

      # Put +text+ into the open prompt, unless something is typed there.
      # @return [Boolean] whether it went in
      def prefill(text) = open? && @reader.prefill(text)

      # What the open prompt holds, nil when none is open: a line typed
      # ahead there is the next turn's input.
      def typed_text = @reader&.typed_text

      # Whether the next turn's input is already here: text typed ahead at
      # the open prompt, or a line a turn took as steering but never merged
      # (it runs as the next turn).
      def waiting_input?
        @lock.synchronize { return true unless @front.empty? }

        !typed_text.to_s.strip.empty?
      end

      # A question answered at the open prompt: the lines submitted from now
      # on go to it, at the ? prompt. What was typed at the prompt is put aside
      # and comes back once the question closes.
      # @yield [Thread::Queue] the answers ([:line, text] or [:interrupt, info])
      # A prompt closed by Ctrl-D mid-turn (the REPL exits after the turn)
      # opens for the question and closes again after it.
      def ask(choice_prompt)
        was_open = open?
        typed = was_open ? @reader.typed_text : nil
        answers = Thread::Queue.new
        @lock.synchronize do
          @answers = answers
          @choice_prompt = choice_prompt
        end
        was_open ? reprompt : start
        yield answers
      ensure
        @lock.synchronize { @answers = nil }
        if !was_open
          stop
        elsif open?
          reprompt(prefill: typed)
        else
          # Ctrl-D at the question ended the reader: start it again.
          start(prefill: typed)
        end
      end

      private

      def reprompt(prefill: nil)
        with_surface_lock do
          @surface.clear_slot(:editor)
          @reader.reprompt(prefill: prefill)
        end
      end

      def with_surface_lock(&)
        @surface.respond_to?(:synchronize) ? @surface.synchronize(&) : yield
      end
    end
  end
end
