# frozen_string_literal: true

require "monitor"
require_relative "line_reader"

module Samagotchi
  class TerminalUI
    # The REPL's input on a terminal: one LineReader keeps a prompt open for
    # the whole session, turns included, and this routes what it reads. A
    # line goes to a question waiting at the prompt (asked as choice>), else
    # to the inbox the REPL loop takes its next line from.
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
        @lock.synchronize { (@answers || @inbox) << item }
        self
      end

      # @return [Array, nil] the next item, nil after +timeout+ seconds
      def pop(timeout:) = @inbox.pop(timeout: timeout)

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

      # A question answered at the open prompt: the lines submitted from now
      # on go to it, at choice>. What was typed at the prompt is put aside
      # and comes back once the question closes.
      # @yield [Thread::Queue] the answers ([:line, text] or [:interrupt, info])
      def ask(choice_prompt)
        typed = @reader.typed_text
        answers = Thread::Queue.new
        @lock.synchronize do
          @answers = answers
          @choice_prompt = choice_prompt
        end
        reprompt
        yield answers
      ensure
        @lock.synchronize { @answers = nil }
        # Ctrl-D at choice> ended the reader: start it again.
        open? ? reprompt(prefill: typed) : start(prefill: typed)
      end

      private

      def reprompt(prefill: nil)
        with_surface_lock do
          @surface.clear_slot(:editor)
          @reader.reprompt(prefill: prefill)
        end
      end

      def with_surface_lock(&block)
        @surface.respond_to?(:synchronize) ? @surface.synchronize(&block) : yield
      end
    end
  end
end
