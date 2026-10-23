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
    # The reply's text is sent by whole lines: a secret the model streams
    # over two chunks is redacted as one (Redact sees the line), and a
    # private key block is withheld from its BEGIN line to its END line.
    # The rest of a line waits for its end, a boundary (a tool call, the
    # turn's end, the owner's question) or MAX_HELD characters (then up to
    # its last space).
    #
    # One per stream (it keeps the partial frame and line between chunks),
    # called from the stream's one thread.
    class ParticipantStreamFilter
      # A partial frame longer than this is dropped (and the rest of it, up
      # to its end): a participant's stream never buffers without bound.
      MAX_FRAME_BYTES = 1_048_576
      FRAME_END = /\r?\n\r?\n/
      PING = ": ping\r\n\r\n"
      # An SSE id is the Bridge's `<seq>-<epoch>` (EventId) or a plain seq.
      EVENT_ID = /\A[0-9A-Za-z.-]{1,64}\z/
      MAX_HELD = 400
      # The events before which the held text goes out.
      FLUSH_BEFORE = %w[tool_call_started turn_completed turn_canceled turn_failed question_requested continue_offered
                        snapshot reset].freeze
      PEM_BEGIN = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/
      PEM_END = /-----END [A-Z0-9 ]*PRIVATE KEY-----/

      def initialize(viewer)
        @viewer = viewer
        @buffer = +""
        @skipping = false
        @held = +""
        @held_iteration = nil
        @in_key = false
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
        id = nil unless id && EVENT_ID.match?(id)
        return chunk(event, shown, id) if shown["type"] == "generation_chunk"

        if shown["type"] == "generation_retrying" && shown["restarted"]
          @held = +""
          return frame(id, shown)
        end
        return flush + frame(id, shown) if FLUSH_BEFORE.include?(shown["type"])

        frame(id, shown)
      end

      # A reply chunk: its text joins the held line; the whole lines go out.
      def chunk(event, shown, id)
        @held_iteration = shown["iteration"]
        @held << event["text"].to_s
        cut = @held.rindex("\n")
        cut ||= @held.rindex(/\s/) if @held.size > MAX_HELD
        cut ||= @held.size - 1 if @held.size > MAX_HELD * 4
        return "" unless cut

        text = @held[0..cut]
        @held = @held[(cut + 1)..]
        out = lines_of(text)
        out.empty? ? "" : frame(id, shown.merge("text" => out))
      end

      # The held text as a chunk of its own (no cursor), before a boundary.
      def flush
        return "" if @held.empty?

        text = lines_of(@held)
        @held = +""
        return "" if text.empty?

        frame(nil, { "type" => "generation_chunk", "text" => text, **(@held_iteration ? { "iteration" => @held_iteration } : {}) })
      end

      # +text+'s lines redacted, a private key block's withheld whole.
      def lines_of(text)
        text.each_line.map do |line|
          if @in_key
            @in_key = false if PEM_END.match?(line)
            next ""
          end
          if PEM_BEGIN.match?(line) && !PEM_END.match?(line)
            @in_key = true
            next "#{ParticipantView::Redact::MARK}#{"\n" if line.end_with?("\n")}"
          end
          ParticipantView::Redact.text(line, @viewer)
        end.join
      end

      def frame(id, shown)
        lines = []
        lines << "id: #{id}" if id
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
