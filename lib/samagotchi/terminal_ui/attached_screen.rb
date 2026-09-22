# frozen_string_literal: true

require "io/console"
require "monitor"
require "reline"

module Samagotchi
  class TerminalUI
    # The only writer to the terminal in attached mode, where Bridge events
    # arrive while the user may be typing at a Reline prompt.
    #
    # The screen, bottom up: the prompt (when Reline has one drawn), one
    # optional status line right above it (thinking tail, running tool), and
    # the permanent output above that. Every change is one flush: move up
    # over the status line and the prompt, clear to the end of the screen,
    # print the new lines and the status line, and have Reline redraw the
    # prompt with the typed text below them.
    #
    # Reline has no API for this, so RelineCanvas reaches into its line
    # editor (checked against reline 0.6.x), and LineEditorHooks runs
    # Reline's own drawing under this screen's lock so the two never
    # interleave. Without a compatible Reline the screen prints plainly, and
    # output may cross an open prompt.
    class AttachedScreen
      # Reline's line editor, seen as the region the prompt occupies.
      class RelineCanvas
        def self.supported?
          defined?(Reline::LineEditor) && Reline.respond_to?(:core) &&
            Reline::LineEditor.method_defined?(:render) &&
            Reline::LineEditor.method_defined?(:render_finished) &&
            Reline::LineEditor.private_method_defined?(:clear_rendered_screen_cache)
        end

        # @return [Boolean] Reline has a prompt drawn on the screen now
        def drawn?
          !rendered_screen&.lines.to_a.empty?
        end

        # @return [Integer] the cursor's row inside the drawn prompt
        def cursor_y
          rendered_screen&.cursor_y.to_i
        end

        # Draw the prompt afresh at the cursor (after output moved it down).
        def redraw!
          forget_rendered!
          editor&.render
        end

        # Forget what Reline drew: its next render starts at the cursor.
        def forget_rendered!
          editor&.send(:clear_rendered_screen_cache)
        end

        private

        def editor
          Reline.core.line_editor
        rescue StandardError
          nil
        end

        def rendered_screen
          editor&.instance_variable_get(:@rendered_screen)
        end
      end

      # No prompt support: everything prints where the cursor is.
      class PlainCanvas
        def drawn? = false
        def cursor_y = 0
        def redraw! = nil
        def forget_rendered! = nil
      end

      # Prepended to Reline::LineEditor: its drawing runs under the attached
      # screen's lock, and a finishing prompt first erases the status line so
      # the submitted line takes its place instead of leaving it stale above.
      module LineEditorHooks
        class << self
          attr_accessor :screen
        end

        def render
          screen = LineEditorHooks.screen
          return super unless screen

          screen.synchronize { super }
        end

        def render_finished
          screen = LineEditorHooks.screen
          return super unless screen

          screen.synchronize do
            screen.prompt_finishing(cursor_y: @rendered_screen.cursor_y)
            super
          end
        end
      end

      # A screen on the real terminal, hooked into Reline when it can be.
      # Call #detach when done.
      def self.attach(out: $stdout)
        if RelineCanvas.supported?
          Reline::LineEditor.prepend(LineEditorHooks) unless Reline::LineEditor.ancestors.include?(LineEditorHooks)
          screen = new(out: out, canvas: RelineCanvas.new)
          LineEditorHooks.screen = screen
        else
          screen = new(out: out, canvas: PlainCanvas.new)
        end
        screen
      end

      # @param out [IO]
      # @param canvas [#drawn?, #cursor_y, #redraw!, #forget_rendered!]
      # @param width [#call] terminal columns
      def initialize(out:, canvas:, width: -> { IO.console&.winsize&.last || 80 })
        @out = out
        @canvas = canvas
        @width = width
        @lock = Monitor.new
        @status = nil
        @status_shown = false
      end

      def synchronize(&) = @lock.synchronize(&)

      # @return [Integer] terminal width in columns
      def columns = @width.call.to_i

      # Print permanent output (may hold several lines).
      def print_line(text)
        flush(text.to_s.split("\n", -1))
      end

      # Show +text+ as the status line, or remove it with nil.
      def status=(text)
        text = text && fit(text.to_s)
        synchronize do
          next if text == @status

          @status = text
          flush([])
        end
      end

      # Called by LineEditorHooks, under the lock, before Reline writes a
      # submitted line: erase the status line and what Reline drew, so the
      # submitted line starts where the status line was.
      def prompt_finishing(cursor_y:)
        return unless @status_shown

        @out.write("\e[#{cursor_y + 1}A\r\e[J")
        @out.flush
        @canvas.forget_rendered!
        @status_shown = false
      end

      # Erase the prompt Reline has drawn (its read is about to be dropped
      # and started again with another prompt).
      def erase_prompt
        synchronize do
          next unless @canvas.drawn?

          up = @canvas.cursor_y
          @out.write("#{"\e[#{up}A" if up.positive?}\r\e[J")
          @out.flush
          @canvas.forget_rendered!
        end
      end

      def detach
        LineEditorHooks.screen = nil if LineEditorHooks.screen.equal?(self)
      end

      private

      def flush(lines)
        synchronize do
          drawn = @canvas.drawn?
          up = (drawn ? @canvas.cursor_y : 0) + (@status_shown ? 1 : 0)
          buffer = +""
          buffer << "\e[#{up}A" if up.positive?
          buffer << "\r\e[J"
          lines.each { |line| buffer << line << "\r\n" }
          buffer << @status << "\r\n" if @status
          @status_shown = !@status.nil?
          @out.write(buffer)
          @out.flush
          @canvas.redraw! if drawn
        end
      end

      # One terminal row at most (a wrapped status line would throw off the
      # next flush's cursor movement).
      def fit(text)
        text = text.gsub(/\e\[[0-9;]*m/, "").tr("\r\n\t", "   ")
        max = [columns - 1, 1].max
        text.length > max ? text[0, max] : text
      end
    end
  end
end
