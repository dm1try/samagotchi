# frozen_string_literal: true

require "io/console"
require "monitor"
require_relative "surface"

module Samagotchi
  class TerminalUI
    # Both TUIs' Surface when a live region can't be drawn (output or
    # input not a terminal, TERM=dumb, or a Reline the seam doesn't support):
    # append-only output. Committed text and the notes, status and hints rows
    # print as lines. The activity slot is dropped, because redrawing it in
    # place needs cursor movement (the turn's lines still print as they end).
    # The prompt is Reline's own, so output may cross it; the editor slot
    # prints the prompt of a plain read (the REPL's ? off a terminal).
    class PlainSurface
      include Surface

      # @param out [IO, nil] nil writes to $stdout as it is at each write
      #   (specs swap it after the UI is built)
      def initialize(out: nil)
        @out = out
        @lock = Monitor.new
      end

      def synchronize(&) = @lock.synchronize(&)

      # @return [Integer] terminal width in columns
      def columns = IO.console&.winsize&.last || 80

      def commit(text)
        synchronize { out.puts(text) }
      end

      def set_slot(name, rows)
        check_slot!(name)
        return if name == :activity
        return synchronize { out.print(Array(rows).join("\n")) && out.flush } if name == :editor

        synchronize { lay_out(rows, width: columns).each { |row| out.puts(row) } }
      end

      # Nothing printed can be taken back.
      # @return [false]
      def clear_slot(name)
        check_slot!(name)
        false
      end

      def close; end

      private

      def out = @out || $stdout
    end
  end
end
