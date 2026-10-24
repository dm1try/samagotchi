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
    # private key block is withheld from its BEGIN line to its END line (a
    # block left open, to the turn's end: TURN_BOUNDARY).
    # The rest of a line waits for its end, a boundary (a tool call, the
    # turn's end, the owner's question) or MAX_HELD characters (then up to
    # its last space). A cut never splits a secret: never inside what
    # Redact would redact in the held text, nor after a key word whose
    # value is still to come (Redact::OPEN_VALUE); past MAX_HELD * 4 with
    # no such space, the held text goes out redacted but its last unbroken
    # run, which with the rest of its line is one [redacted].
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
      # A turn's start and end: a private key block the reply left open is
      # withheld to here (fail closed within the turn), not to the stream's
      # end.
      TURN_BOUNDARY = %w[turn_started turn_completed turn_canceled turn_failed].freeze
      PEM_BEGIN = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/
      PEM_END = /-----END [A-Z0-9 ]*PRIVATE KEY-----/

      def initialize(viewer)
        @viewer = viewer
        @buffer = +""
        @skipping = false
        @held = +""
        @held_iteration = nil
        @in_key = false
        # While a hard cut drops the rest of its line (#hard_cut): the last
        # of what it dropped, and whether that holds a key's BEGIN line.
        @dropped = nil
        @dropped_key = false
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
          @dropped = nil
          return frame(id, shown)
        end
        boundary = TURN_BOUNDARY.include?(shown["type"])
        return frame(id, shown) unless boundary || FLUSH_BEFORE.include?(shown["type"])

        out = flush
        @in_key = @dropped_key = false if boundary
        out + frame(id, shown)
      end

      # A reply chunk: its text joins the held line; the whole lines go out.
      def chunk(event, shown, id)
        @held_iteration = shown["iteration"]
        @held << undropped(event["text"].to_s)
        cut = safe_cut
        return hard_cut(id, shown) if cut.nil? && @held.size > MAX_HELD * 4
        return "" unless cut

        text = @held[0..cut]
        @held = @held[(cut + 1)..]
        out = lines_of(text)
        out.empty? ? "" : frame(id, shown.merge("text" => out))
      end

      # MAX_HELD * 4 held with no safe cut (one unbroken run, mostly): the
      # held text goes out redacted but for its last run, which with the rest
      # of its line is one MARK (fail closed: it may be a secret's start).
      def hard_cut(id, shown)
        text = @held.sub(/\S*\z/, "")
        # A key word or a key's BEGIN line before that run goes with it.
        open = ParticipantView::Redact::OPEN_VALUE.match(text[-80..] || text)
        text = text[0, text.size - open[0].size] if open
        @dropped = +""
        @dropped_key = false
        dropping = @held[text.size..]
        @held = +""
        @held << undropped(dropping)
        frame(id, shown.merge("text" => "#{lines_of(text)}#{ParticipantView::Redact::MARK}"))
      end

      # The last newline (past MAX_HELD, the last space) the held text may
      # be cut after: not inside a secret Redact would match in it, and not
      # where a secret's value would follow. nil: hold on.
      def safe_cut
        spaces = (@held.size > MAX_HELD ? /\s/ : /\n/)
        spans = nil
        at = @held.size
        while (at = at.positive? && @held.rindex(spaces, at - 1))
          spans ||= secret_spans(@held)
          return at unless spans.any? { |from, to| from <= at && at < to } || open_value?(at)
        end
        nil
      end

      # Whether the held text up to +at+ (a cut's last character) ends where
      # a secret's value would go on.
      def open_value?(at)
        from = [at - 80, 0].max
        ParticipantView::Redact::OPEN_VALUE.match?(@held[from..at])
      end

      SPAN_PATTERNS = (ParticipantView::Redact::PATTERNS - [ParticipantView::Redact::PRIVATE_KEY] +
                       ParticipantView::Redact::VALUES).freeze

      # [from, to) of every match Redact would redact in +text+ (but a
      # private key's block: lines_of withholds it by its lines).
      def secret_spans(text)
        literals = @viewer.secrets.map { |secret| Regexp.new(Regexp.escape(secret)) }
        (literals + SPAN_PATTERNS).flat_map do |pattern|
          text.to_enum(:scan, pattern).map { Regexp.last_match.offset(0) }
        end
      end

      # +text+ without what a hard cut drops: the rest of its line. A
      # private key's BEGIN line in what it dropped (read through a window:
      # the line may be long) withholds its block still.
      def undropped(text)
        return text unless @dropped

        line_end = text.index("\n")
        window = @dropped + text[0, line_end || text.size]
        last_begin = window.rindex(PEM_BEGIN)
        last_end = window.rindex(PEM_END)
        @dropped_key = (last_begin || -1) > (last_end || -1) if last_begin || last_end
        @dropped = window[-DROPPED_WINDOW..] || window
        return "" unless line_end

        @in_key = true if @dropped_key
        @dropped = nil
        text[line_end..]
      end

      # Longer than a BEGIN or END line.
      DROPPED_WINDOW = 80

      # The held text as a chunk of its own (no cursor), before a boundary.
      def flush
        @dropped = nil
        return "" if @held.empty?

        text = lines_of(@held)
        @held = +""
        return "" if text.empty?

        frame(nil, { "type" => "generation_chunk", "text" => text, **(@held_iteration ? { "iteration" => @held_iteration } : {}) })
      end

      # +text+ redacted (each run of lines as one, so a secret over a line
      # break is redacted as one), a private key block's withheld whole.
      def lines_of(text)
        out = +""
        run = +""
        text.each_line do |line|
          if @in_key
            @in_key = opens_key?(line) if PEM_END.match?(line)
          elsif opens_key?(line)
            out << ParticipantView::Redact.text(run, @viewer)
            run = +""
            @in_key = true
            out << "#{ParticipantView::Redact::MARK}#{"\n" if line.end_with?("\n")}"
          else
            run << line
          end
        end
        out << ParticipantView::Redact.text(run, @viewer)
      end

      # Whether +line+ leaves a private key block open: a BEGIN line with
      # no END after it (an END and the next BEGIN may share a line).
      def opens_key?(line)
        last_begin = line.rindex(PEM_BEGIN) or return false
        last_end = line.rindex(PEM_END)
        last_end.nil? || last_begin > last_end
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
