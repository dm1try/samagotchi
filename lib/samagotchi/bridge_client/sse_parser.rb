# frozen_string_literal: true

module Samagotchi
  class BridgeClient
    # Incremental Server-Sent Events parser: feed it raw body chunks as they
    # arrive and it yields one frame per blank-line-terminated event. Accepts
    # CRLF or LF line ends, joins multi-line `data:` with newlines, and skips
    # comments (the Bridge's `: ping` heartbeats) and frames without data.
    class SSEParser
      def initialize
        @buffer = +""
        reset_frame
      end

      # @param chunk [String] raw bytes from the stream
      # @yieldparam frame [Hash] {id: String|nil, event: String|nil, data: String}
      def feed(chunk)
        @buffer << chunk.to_s.b
        while (newline = @buffer.index("\n"))
          line = @buffer.slice!(0..newline).chomp("\n").chomp("\r").force_encoding(Encoding::UTF_8)
          if line.empty?
            yield({ id: @id, event: @event, data: @data.join("\n") }) if @data.any?
            reset_frame
          else
            field(line)
          end
        end
      end

      private

      def field(line)
        return if line.start_with?(":")

        name, value = line.split(":", 2)
        value = value.to_s.delete_prefix(" ")
        case name
        when "id" then @id = value
        when "event" then @event = value
        when "data" then @data << value
        end
      end

      def reset_frame
        @id = nil
        @event = nil
        @data = []
      end
    end
  end
end
