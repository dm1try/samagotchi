# frozen_string_literal: true

require "io/console"
require "monitor"
require "reline"
require "stringio"
require_relative "surface"

module Samagotchi
  class TerminalUI
    # The only writer to the terminal while a live region is on (attached
    # mode). The bottom of the screen is the live region, its slots top down:
    # activity (spinner, thinking tail), editor (the Reline prompt and its
    # completion dialog, fed by RelineSeam), then status, notes and hints.
    # Everything above it is normal scrollback: no alternate screen, so
    # scrolling and copy/paste stay the terminal's own.
    #
    # Every change is one frame under the lock: move up to the top of the
    # region, clear to the end of the screen (ESC[J), print any committed
    # text, and draw the region again with the cursor back in the editor.
    # Committed text may wrap; the region's rows are clipped to the width,
    # so the move up is exact and the region can't drift.
    class Screen
      include Surface

      # The slots below the editor, and the order they give way in when
      # the terminal is short: hints first, then notes, then status.
      BELOW = %i[status notes hints].freeze
      SYNC_BEGIN = "\e[?2026h\e[?25l"
      SYNC_END = "\e[?25h\e[?2026l"

      # @param out [IO]
      # @param size [#call] -> [rows, columns] of the terminal
      def initialize(out:, size: -> { IO.console&.winsize || [24, 80] })
        @out = out
        @size = size
        @lock = Monitor.new
        @slots = {}
        @editor = []
        @editor_cursor = [0, 0]
        @cursor_row = 0
      end

      def synchronize(&) = @lock.synchronize(&)

      # @return [Integer] terminal width in columns
      def columns = [@size.call.last.to_i, 1].max

      # @return [Integer] terminal height in rows
      def rows = [@size.call.first.to_i, 1].max

      # Print permanent output (may hold several lines) above the region.
      def commit(text)
        lines = text.to_s.split("\n", -1)
        synchronize { frame { |buffer| lines.each { |line| buffer << line << "\r\n" } } }
        nil
      end

      # The editor slot is Reline's: RelineSeam feeds it with #draw_editor.
      def set_slot(name, rows) = set_slots(name => rows)

      # One frame for all the slots given, none when nothing changed.
      def set_slots(**rows_by_slot)
        rows_by_slot = rows_by_slot.to_h do |name, rows|
          check_slot!(name)
          raise ArgumentError, "Reline draws the editor slot" if name == :editor

          [name, Array(rows).map { |row| one_row(row) }]
        end
        synchronize do
          next if rows_by_slot.all? { |name, rows| slot(name) == rows }

          rows_by_slot.each { |name, rows| rows.empty? ? @slots.delete(name) : (@slots[name] = rows) }
          frame
        end
        nil
      end

      # Clearing the editor slot drops the prompt from the region (its read
      # is about to be dropped and started again).
      # @return [Boolean] whether the slot showed anything
      def clear_slot(name)
        check_slot!(name)
        synchronize do
          next finish_editor if name == :editor
          next false unless @slots.key?(name)

          @slots.delete(name)
          frame
          true
        end
      end

      # Rows the editor may take (its prompt, wrapped input and completion
      # dialog), so that the region fits on the screen with the activity and
      # status rows. Notes and hints give way to the editor instead.
      def editor_budget
        synchronize { [rows - 1 - slot(:activity).size - slot(:status).size, 1].max }
      end

      # Reline rendered: +lines+ are its rows of [x, width, content] layers
      # (prompt, input, dialog), the cursor is at (+cursor_x+, +cursor_y+)
      # inside them.
      def draw_editor(lines, cursor_x, cursor_y)
        synchronize do
          @editor = lines.map { |layers| compose(layers) }
          @editor_cursor = [cursor_x, cursor_y]
          frame
        end
        nil
      end

      # The prompt ended. +lines+ (the submitted text, or the text with ^C)
      # go to scrollback; without them the prompt just disappears.
      # @return [Boolean] whether a prompt was shown
      def finish_editor(lines = nil)
        synchronize do
          shown = !@editor.empty?
          next false unless shown || lines

          @editor = []
          @editor_cursor = [0, 0]
          frame { |buffer| lines&.each { |line| buffer << line << "\r\n" } }
          shown
        end
      end

      # Ctrl-L: clear the screen and draw the region at the top.
      def clear_screen
        synchronize do
          @cursor_row = 0
          frame(clear: true)
        end
      end

      # Draw the region again (after a resize).
      def redraw
        synchronize { frame }
      end

      # Take over what else writes to the terminal while the screen is on:
      # $stderr (warnings from background threads would cross the region)
      # and SIGWINCH outside a read (Reline traps it only during one, and
      # chains to this trap then). #close gives both back.
      # @return [self]
      def start
        @stderr_was = $stderr
        $stderr = ErrorOutput.new(self)
        # A trap handler can't take the lock: redraw from a thread.
        @winch_was = Signal.trap("WINCH") { Thread.new { redraw } }
        self
      rescue ArgumentError
        self # no SIGWINCH on this platform
      end

      # Erase the region and leave the cursor where it began; put back what
      # #start took over.
      def close
        if @stderr_was
          $stderr.flush
          $stderr = @stderr_was
          @stderr_was = nil
        end
        Signal.trap("WINCH", @winch_was) if @winch_was
        @winch_was = nil
        synchronize do
          @slots.clear
          @editor = []
          frame
        end
      end

      # $stderr while a Screen is on: each line written goes above the region
      # as committed output. A line without its newline waits for the rest.
      class ErrorOutput
        def initialize(screen)
          @screen = screen
          @pending = +""
          @lock = Mutex.new
        end

        def write(*parts)
          text = parts.join
          lines = @lock.synchronize do
            @pending << text
            *done, @pending = @pending.split("\n", -1)
            @pending = +@pending.to_s
            done
          end
          lines.each { |line| @screen.commit(line) }
          text.bytesize
        end

        def print(*parts)
          write(*parts)
          nil
        end

        def puts(*items)
          io = StringIO.new
          io.puts(*items)
          write(io.string)
          nil
        end

        def <<(item)
          write(item)
          self
        end

        # Commit a line still waiting for its newline.
        def flush
          line = @lock.synchronize { @pending.empty? ? nil : @pending.dup.tap { @pending.clear } }
          @screen.commit(line) if line
          self
        end

        def sync = true
        def sync=(_value); end
        def tty? = false
        alias isatty tty?
        def fileno = nil
      end

      private

      def slot(name) = @slots.fetch(name, [])

      # One frame: erase the region, let the block add scrollback text, draw
      # the region. Written in one piece and never cut short by
      # Thread#raise (LineReader drops a read that way).
      def frame(clear: false)
        Thread.handle_interrupt(Object => :never) do
          buffer = +SYNC_BEGIN
          buffer << "\e[2J\e[H" if clear
          buffer << "\r"
          buffer << "\e[#{@cursor_row}A" if @cursor_row.positive?
          buffer << "\e[J"
          @cursor_row = 0
          yield buffer if block_given?
          buffer << region
          buffer << SYNC_END
          @out.write(buffer)
          @out.flush
        end
      end

      # The region's rows, leaving the cursor in the editor (or on the row
      # below the region when no prompt is open). Sets @cursor_row.
      def region
        width = columns
        above = slot(:activity)
        below = BELOW.flat_map { |name| slot(name) }
        spare = rows - 1 - above.size - @editor.size
        below = below.first([spare, 0].max)
        above = above.last([rows - 1 - @editor.size, 0].max)
        all = above + @editor + below
        return +"" if all.empty?

        text = all.map { |row| clip(row, width) }.join("\r\n")
        last = all.size - 1
        if @editor.empty?
          text << "\r\n"
          @cursor_row = last + 1
        else
          target = above.size + @editor_cursor[1].clamp(0, @editor.size - 1)
          text << "\e[#{last - target}A" if last > target
          text << "\r"
          text << "\e[#{@editor_cursor[0]}C" if @editor_cursor[0].positive?
          @cursor_row = target
        end
        text
      end

      # A slot row is one line: no line breaks or tabs.
      def one_row(row) = row.to_s.tr("\r\n\t", "   ")

      # Cut a row to the terminal width, so it takes exactly one row.
      def clip(row, width)
        return row if Reline::Unicode.calculate_width(row, true) <= width

        "#{Reline::Unicode.take_mbchar_range(row, 0, width, padding: false).first}\e[0m"
      end

      # Lay Reline's layers (prompt, input, dialog rows) over each other into
      # one row, as Reline's own render_line_differential would draw them.
      def compose(layers)
        base = +""
        layers.each do |layer|
          next unless layer

          x, w, content = layer
          base_width = Reline::Unicode.calculate_width(base, true)
          base << (" " * (x - base_width)) if base_width < x
          head, = Reline::Unicode.take_mbchar_range(base, 0, x, padding: true)
          tail, = Reline::Unicode.take_mbchar_range(base, x + w, [base_width - x - w, 0].max, padding: true)
          base = "#{head}\e[0m#{content}\e[0m#{tail}"
        end
        base
      end
    end
  end
end
