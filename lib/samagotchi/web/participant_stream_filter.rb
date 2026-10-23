# frozen_string_literal: true

require "json"
require_relative "participant_view"

module Samagotchi
  module Web
    # A participant's stream (App#stream_filter): the Bridge's SSE bytes,
    # read in chunks that split frames anywhere, cut into whole frames, and
    # each frame's event rebuilt by ParticipantView.event. A frame whose
    # event is dropped sends nothing; a comment (the Bridge's `: ping`)
    # goes on as a ping; anything that doesn't parse is dropped. Frames are
    # written again from the filtered event (its `id:` the Bridge's cursor,
    # `event:` the filtered type), never passed through as bytes.
    #
    # One per stream (it keeps the partial frame between chunks), called
    # from the stream's one thread.
    class ParticipantStreamFilter
      # A partial frame longer than this is dropped (and the rest of it, up
      # to its end): a participant's stream never buffers without bound.
      MAX_FRAME_BYTES = 1_048_576
      FRAME_END = /\r?\n\r?\n/
      PING = ": ping\r\n\r\n"
      # An SSE id is the Bridge's `<seq>-<epoch>` (EventId) or a plain seq.
      EVENT_ID = /\A[0-9A-Za-z.-]{1,64}\z/

      def initialize(viewer)
        @viewer = viewer
        @buffer = +""
        @skipping = false
      end

      # @param chunk [String] the Bridge's next read
      # @return [String] the frames to send ("" for none)
      def call(chunk)
        @buffer << chunk.to_s.b
        out = +""
        while (match = FRAME_END.match(@buffer))
          frame = @buffer[0, match.begin(0)]
          @buffer = @buffer[match.end(0)..]
          if @skipping
            @skipping = false
            next
          end
          out << rewrite(frame)
        end
        if @buffer.bytesize > MAX_FRAME_BYTES
          @buffer = +""
          @skipping = true
        end
        out
      end

      private

      def rewrite(frame)
        text = frame.dup.force_encoding(Encoding::UTF_8)
        return "" unless text.valid_encoding?

        lines = text.split(/\r?\n/)
        return PING if lines.all? { |line| line.start_with?(":") }

        id = nil
        data = []
        lines.each do |line|
          if line.start_with?("id:") then id = line.delete_prefix("id:").strip
          elsif line.start_with?("data:") then data << line.delete_prefix("data:").delete_prefix(" ")
          end
        end
        event = parse(data.join("\n")) or return ""
        shown = ParticipantView.event(event, @viewer) or return ""

        lines = []
        lines << "id: #{id}" if id && EVENT_ID.match?(id)
        lines << "event: #{shown["type"]}"
        lines << "data: #{JSON.generate(shown)}"
        "#{lines.join("\r\n")}\r\n\r\n"
      end

      def parse(json)
        value = JSON.parse(json)
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
