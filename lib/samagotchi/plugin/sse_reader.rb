# frozen_string_literal: true

module Samagotchi
  module Plugin
    class Http
      # A plain Server-Sent Events reader (ctx.http.stream's Stream#each_event),
      # fed the body's chunks as they arrive:
      #
      #   reader = SseReader.new
      #   reader.feed(chunk) { |event| … }   # each event whose blank line came
      #
      # The fields are `event`, `data` and `id`; several `data:` lines join
      # with "\n"; one space after the colon is dropped; a line starting
      # with ":" is a comment. Lines end in "\n", "\r\n" or "\r", and a
      # chunk may end anywhere (mid-line, between "\r" and "\n", inside a
      # UTF-8 character): bytes are kept until an event is whole, and its
      # text is decoded then. An event is dispatched at its blank line; one
      # the body's end cuts off is dropped; an event without data isn't
      # yielded. The last `id` carries over to later events, as in a
      # browser's EventSource.
      class SseReader
        # One event: +type+ is "message" when the stream named none.
        Event = Data.define(:type, :data, :id)

        BOM = "\xEF\xBB\xBF".b

        def initialize
          @buffer = +"".b
          @skip_lf = false
          @started = false
          @id = nil
          reset
        end

        # @param chunk [String] the next bytes of the body
        # @yield [Event] each event the chunk completes
        # @return [void]
        def feed(chunk, &)
          bytes = chunk.to_s.b
          return if bytes.empty?

          if @skip_lf
            @skip_lf = false
            bytes = bytes.delete_prefix("\n")
          end
          @buffer << bytes
          unless @started
            return if BOM.start_with?(@buffer) # all of it may still be a BOM

            @started = true
            @buffer = @buffer.delete_prefix(BOM)
          end
          lines(&)
        end

        private

        def lines(&)
          while (at = @buffer.index(/[\r\n]/))
            line = @buffer.byteslice(0, at)
            ending = if @buffer.byteslice(at, 2) == "\r\n" then 2
                     else
                       @skip_lf = true if @buffer.bytesize == at + 1 && @buffer.byteslice(at) == "\r"
                       1
                     end
            @buffer = @buffer.byteslice((at + ending)..)
            line(line, &)
          end
        end

        def line(line, &)
          return dispatch(&) if line.empty?
          return if line.start_with?(":")

          field, value = line.split(":", 2)
          value = value.to_s.delete_prefix(" ")
          case field
          when "event" then @type = value
          when "data" then (@data ||= []) << value
          when "id" then @id = text(value) unless value.include?("\0")
          end
        end

        def dispatch
          data = @data
          type = @type
          reset
          return unless data

          yield Event.new(type: type.nil? || type.empty? ? "message" : text(type), data: text(data.join("\n")), id: @id)
        end

        def reset
          @data = nil
          @type = nil
        end

        # The event's bytes as UTF-8, a broken sequence replaced.
        def text(bytes) = bytes.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
