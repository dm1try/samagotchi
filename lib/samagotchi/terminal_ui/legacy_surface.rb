# frozen_string_literal: true

require_relative "surface"

module Samagotchi
  class TerminalUI
    # The REPL's Surface before the live region: plain output where the
    # cursor is. Only the activity slot is live. It redraws in place by
    # moving back up over the rows it drew last (ESC[nA), which works only
    # while nothing else writes below it. The editor slot prints a prompt
    # for a plain read, and clearing it erases the line Reline drew. The other
    # slots just print their rows, except status rows set together with the
    # activity rows (#set_slots): those are the activity block's last rows.
    class LegacySurface
      include Surface

      # @param out [IO, nil] nil writes to $stdout as it is at each write
      #   (specs swap it after the UI is built)
      def initialize(out: nil)
        @out = out
        @activity_shown = false
        @activity_rows = 0
      end

      def commit(text)
        out.puts(text)
      end

      def set_slot(name, rows)
        check_slot!(name)
        case name
        when :activity then redraw_activity(rows)
        when :editor
          out.print(rows.join("\n"))
          out.flush
        else rows.each { |row| out.puts(row) }
        end
      end

      def set_slots(**rows_by_slot)
        return super unless rows_by_slot.key?(:activity)

        activity = rows_by_slot.delete(:activity)
        status = rows_by_slot.delete(:status)
        set_slot(:activity, Array(activity) + Array(status))
        super(**rows_by_slot)
      end

      def clear_slot(name)
        check_slot!(name)
        case name
        when :activity then erase_activity
        when :editor
          out.print("\r\e[2K")
          out.flush
          true
        else false
        end
      end

      private

      def out = @out || $stdout

      # Pad to the taller of the old and new heights, so rows left over from
      # a taller frame are blanked.
      def redraw_activity(rows)
        move_to_activity_origin
        row_count = [@activity_rows, rows.length].max
        padded = rows + Array.new(row_count - rows.length, "")
        out.print(padded.map { |text| "#{text}\e[0K" }.join("\n"))
        out.flush
        @activity_shown = true
        @activity_rows = row_count
      end

      def move_to_activity_origin
        return unless @activity_shown

        out.print("\e[#{@activity_rows - 1}A") if @activity_rows > 1
        out.print("\r")
      end

      def erase_activity
        return false unless @activity_shown

        row_count = @activity_rows
        row_count = 1 if row_count <= 0
        out.print("\e[#{row_count - 1}A") if row_count > 1
        out.print("\r")
        row_count.times do |index|
          out.print("\e[0K")
          out.print("\n") if index < row_count - 1
        end
        out.print("\e[#{row_count - 1}A") if row_count > 1
        out.print("\r")
        out.flush
        @activity_shown = false
        @activity_rows = 0
        true
      end
    end
  end
end
