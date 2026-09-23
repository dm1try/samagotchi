# frozen_string_literal: true

require "reline"

module Samagotchi
  class TerminalUI
    # Reads input lines on its own thread, so output keeps rendering while
    # the user types, and hands each line (nil = Ctrl-D) or Ctrl-C to a sink
    # (anything with #<<, such as a Thread::Queue); the attached loop and the
    # REPL both read this way. #reprompt makes it drop the open read and start
    # again with the current prompt (a question opened or closed); #prefill
    # starts it again with text already typed in (a failed prompt).
    class LineReader
      # Raised into the reader thread; only lands inside a read.
      class Reprompt < StandardError; end
      # Ends the reader from inside its read, so Reline restores the terminal.
      class Stop < StandardError; end

      # @param prompt [#call] -> the prompt for the next read
      # @param read [#call] (prompt, prefill) -> line (nil = Ctrl-D)
      # @param prefill [String, nil] typed into the first read
      def initialize(sink, prompt:, read:, prefill: nil)
        @sink = sink
        @prompt = prompt
        @read = read
        @current = nil
        @prefill = prefill
      end

      # @return [String, nil] the prompt of the read in progress
      attr_reader :current

      def start
        # Created masked (threads inherit the mask), so a Reprompt raised
        # before #run is entered waits for the first read too.
        Thread.handle_interrupt(Reprompt => :never, Stop => :never) { @thread = Thread.new { run } }
        @thread.report_on_exception = false
        self
      end

      def reprompt
        @thread&.raise(Reprompt)
      end

      # Start the read again with +text+ in it, unless something is typed
      # there already (that would be lost).
      # @return [Boolean] whether the text went in
      def prefill(text)
        return false unless line_empty?

        @prefill = text
        reprompt
        true
      end

      def stop
        return unless @thread&.alive?

        @thread.raise(Stop)
        @thread.join(0.5) || (@thread.kill && @thread.join(0.5))
      end

      private

      def run
        # A Reprompt may only interrupt the read itself; one that comes
        # while a line is being handed over waits for the next read (and
        # just restarts it). The mask is also inherited from #start.
        Thread.handle_interrupt(Reprompt => :never, Stop => :never) do
          loop do
            @current = @prompt.call
            prefill = @prefill
            @prefill = nil
            line = Thread.handle_interrupt(Reprompt => :immediate, Stop => :immediate) { @read.call(@current, prefill) }
            @sink << [:line, line]
            break if line.nil?
          rescue Reprompt
            next
          rescue Interrupt
            # What the line held at the press (AttachedLoop#note_interrupted_line).
            @sink << [:interrupt, Thread.current[:interrupted_line]]
            Thread.current[:interrupted_line] = nil
          end
        end
      rescue Stop
        nil
      end

      def line_empty?
        return true unless $stdin.tty?

        Reline.line_buffer.to_s.strip.empty?
      rescue StandardError
        true
      end
    end
  end
end
