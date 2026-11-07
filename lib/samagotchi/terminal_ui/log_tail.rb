# frozen_string_literal: true

require_relative "../log"
require_relative "../log_line"
require_relative "../degrade"

module Samagotchi
  class TerminalUI
    # `chi -v` attached: the debug log's new records of one session (its
    # sid), followed from where the file ends as it starts, each handed to
    # +on_record+ (AttachLauncher commits it above the live region). The
    # worker writes to the file this chi spawned it with
    # (SAMAGOTCHI_LOG_FILE); a rotation (DebugLog renames the file to .1) is
    # seen as another inode or a shorter file, and the new one is read from
    # its start.
    class LogTail
      POLL_INTERVAL = 0.2

      # @param path [String] the debug log (Log.path)
      # @param session_id [String] whose records are shown (its first
      #   Log::SID_LENGTH chars are the records' sid)
      # @param on_record [#call] LogLine::Record ->, on the tail's thread
      def initialize(path:, session_id:, on_record:, poll_interval: POLL_INTERVAL)
        @path = path
        @sid = session_id.to_s[0, Log::SID_LENGTH]
        @on_record = on_record
        @poll_interval = poll_interval
        @io = nil
        @ino = nil
        @buffer = +""
        @record = nil
      end

      # Start following from the file's current end.
      # @return [self]
      def start
        open_at(:end)
        @thread = Thread.new { follow }
        @thread.report_on_exception = false
        self
      end

      # The records written since the last look are shown first.
      def stop
        @thread&.kill
        @thread&.join(1)
        Degrade.call(:attached, "log_tail_failed") { poll } if @thread
        @io&.close
        @io = nil
      end

      # One look: the lines written since the last (tests call it directly).
      def poll
        reopen_if_rotated
        return unless @io

        drain
        take_lines
      end

      private

      def follow
        loop do
          Degrade.call(:attached, "log_tail_failed") { poll }
          sleep(@poll_interval)
        end
      end

      # What the open file holds past the last read, into the buffer.
      def drain
        chunk = @io.read_nonblock(1 << 16, exception: false)
        while chunk.is_a?(String)
          @buffer << chunk
          chunk = @io.read_nonblock(1 << 16, exception: false)
        end
      end

      def open_at(where)
        @io = File.open(@path, "rb")
        @ino = @io.stat.ino
        @io.seek(0, IO::SEEK_END) if where == :end
      rescue SystemCallError
        @io = nil # not there yet: the next look opens it
      end

      def reopen_if_rotated
        return open_at(:start) unless @io

        stat = File.stat(@path)
        return if stat.ino == @ino && stat.size >= @io.pos

        # Renamed: what the worker wrote to it since the last look is still
        # there, read before the new file (a truncated one has nothing left).
        drain if stat.ino != @ino
        @io.close
        open_at(:start)
      rescue SystemCallError
        nil # renamed and not written again yet
      end

      # Whole lines only; a payload line joins the record above it. DebugLog
      # writes a record and its payload in one write, so a look ends on a
      # whole record: each one is handed on by the end of the look.
      def take_lines
        while (cut = @buffer.index("\n"))
          line = LogLine.clean(@buffer.slice!(0, cut + 1)).chomp
          if LogLine.payload_line?(line)
            @record.payload = [@record.payload, line.delete_prefix(LogLine::INDENT)].compact.join("\n") if @record
            next
          end
          flush
          @record = LogLine.parse(line)
        end
        flush
      end

      def flush
        record = @record
        @record = nil
        @on_record.call(record) if record && record.sid == @sid
      end
    end
  end
end
