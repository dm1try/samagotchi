# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "../log"
require_relative "../message_time"
require_relative "../steer"

module Samagotchi
  class Bridge
    # A finished turn as live drew it (its drawing), one JSON line per turn in
    # the session's folder (FILE), so a reload or a reconnect draws the turn
    # the way the live page did: the TurnAccumulator's final fold of the turn
    # (its parts in order: steps, rows, notices, steers, merged lines,
    # reminders, in-turn cards) and the end event's display keys (END_KEYS).
    # Display-side only: no request, message, strategy, recap, --resume or
    # continue reads it.
    #
    # A line names the turn's own messages by the range the Engine put on
    # the end event (`kept_from`/`kept_to`: the turn's messages are
    # `kept[from...to]`) and digests both ends (#digest). It holds while the
    # messages still reach `to` and both ends digest the same: a rollback, a
    # rolled-back failure or a prompt handed back drops it. Of two valid
    # lines that overlap (a rollback, then a re-run that said the same at the
    # same boundaries), and of several for one turn id, the newest wins
    # (.valid). A turn with no range (an older worker, a turn that kept
    # nothing) or an empty one writes no line, and draws as before.
    #
    # Written by the accumulator's on_turn_end hook (#append), inside the
    # SessionObserver's delivery: the line is on disk before any stream gets
    # the end frame. That departs from SessionObserver's "enqueue-only" note,
    # as CardStore's save does: one append per turn end.
    class TurnDrawings
      FILE = "turn_drawings.jsonl"
      # In the sidecar's features (Bridge::FEATURES): this worker's CardStore
      # lists an in-turn entry's of_turn, which a page drawing the turn needs
      # to leave that entry to the drawing. chi web draws no drawings for a
      # live worker without it (an older one: its rows would show twice).
      FEATURE = "turn_drawings"
      # A show draws at most this many turns from their drawings, the newest
      # (the payload and the page's offscreen render stay bounded in a long
      # session); older turns draw as before, from their messages.
      SHOWN_MAX = 100
      VERSION = 1
      # The end event's keys the page draws a finished turn's end from (not
      # the answer: its text, html and refs stay the message's; not the range:
      # the line's from/to).
      END_KEYS = %i[type turn_id duration_ms revises verify cancellation_reason cancelled_by summary message error_class
                    kept_steps].freeze
      # What a line keeps of the accumulator's turn.
      DRAWING_KEYS = (%i[prompt turn_id origin continue at images parts] + Steer::AUTHOR_KEYS).uniq.freeze
      KINDS = { "turn_completed" => "completed", "turn_canceled" => "canceled", "turn_failed" => "failed" }.freeze

      # One line of the file (string-keyed drawing and end, as JSON has them).
      Line = Data.define(:v, :turn_id, :kind, :from, :to, :from_digest, :to_digest, :drawing, :end) do
        # @return [Line, nil] nil for a line this chi can't draw (another
        #   version, a missing field, parts that aren't rows: .rows?)
        def self.from_h(raw)
          return nil unless raw.is_a?(Hash) && raw["v"] == VERSION
          return nil unless raw["turn_id"].is_a?(String) && !raw["turn_id"].empty?
          return nil unless raw["from"].is_a?(Integer) && raw["to"].is_a?(Integer) && raw["from"] < raw["to"] && raw["from"] >= 0
          return nil unless raw["from_digest"].is_a?(String) && raw["to_digest"].is_a?(String)
          return nil unless raw["drawing"].is_a?(Hash) && raw["end"].is_a?(Hash)
          return nil unless TurnDrawings.rows?(raw["drawing"]["parts"])

          new(v: raw["v"], turn_id: raw["turn_id"], kind: raw["kind"].to_s, from: raw["from"], to: raw["to"],
              from_digest: raw["from_digest"], to_digest: raw["to_digest"], drawing: raw["drawing"], end: raw["end"])
        end

        def to_h = super.transform_keys(&:to_s)

        def range = (from...to)
      end

      # @param path [String, nil] the file (nil: nothing is written)
      # @param messages [#call] the session's messages now (the Engine's,
      #   as CardStore's): the end step replaced them before the end event, so
      #   they hold the turn's range when #append runs
      def initialize(path:, messages:)
        @path = path
        @messages = messages
        @last = path ? self.class.tail_line(path) : nil
      end

      # The newest line this store wrote or started from (P3's snapshot).
      # @return [Line, nil]
      attr_reader :last

      # The accumulator's hook: the turn's line, when its end event names a
      # range. Never raises (a turn that can't be drawn still ended).
      # @param turn [Hash] the accumulator's final fold (symbol keys)
      # @param end_event [Hash] the end event
      def append(turn, end_event)
        line = line_for(turn, end_event)
        return unless line

        write(line)
        @last = line
      rescue StandardError => e
        Log.warn(:bridge, "turn_drawing_failed", error: "#{e.class}: #{e.message}")
      end

      def line_for(turn, end_event)
        from = end_event[:kept_from]
        to = end_event[:kept_to]
        return nil unless @path && turn && from.is_a?(Integer) && to.is_a?(Integer) && from < to && from >= 0

        messages = @messages.call || []
        return nil if messages.size < to

        id = end_event[:turn_id] || turn[:turn_id]
        return nil unless id

        Line.new(v: VERSION, turn_id: id.to_s, kind: KINDS[end_event[:type].to_s] || end_event[:type].to_s, from: from, to: to,
                 from_digest: self.class.digest(messages[from]), to_digest: self.class.digest(messages[to - 1]),
                 drawing: JSON.parse(JSON.generate(scrubbed(turn.slice(*DRAWING_KEYS)))),
                 end: JSON.parse(JSON.generate(scrubbed(self.class.end_of(end_event)))))
      end
      private :line_for

      # Newline-first: a torn last line (a crash mid-write) ends before this
      # one starts, so both parse apart; then one write.
      def write(line)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
          size = file.size
          torn = size.positive? && (file.pread(1, size - 1) != "\n")
          file.write("#{"\n" if torn}#{JSON.generate(line.to_h)}\n")
        end
      end
      private :write

      def scrubbed(value) = self.class.scrub(value)
      private :scrubbed

      class << self
        # Whether a drawing's +parts+ are rows TurnAccumulator.replay_events
        # can unfold: none, or a list of Hashes (a hand-edited line's may be
        # anything, and the unfold would raise).
        def rows?(parts) = parts.nil? || (parts.is_a?(Array) && parts.all?(Hash))

        # The end event's display keys (END_KEYS), with an empty answer's
        # notice from its summary.
        # @return [Hash]
        def end_of(event)
          out = event.slice(*END_KEYS).compact
          out[:type] = out[:type].to_s if out[:type]
          empty = event.dig(:turn_summary, :empty_answer)
          out[:turn_summary] = { empty_answer: empty } if empty
          out
        end

        # A message's digest in one form for the live (symbol keys, raw
        # strings) and the saved (string keys, scrubbed as Session#to_h does)
        # messages: role, content and time, each read from either key.
        # @return [String]
        def digest(message)
          return "" unless message.is_a?(Hash)

          role = fetch(message, :role)
          time = fetch(message, MessageTime::KEY)
          Digest::SHA1.hexdigest(JSON.generate(scrub([role&.to_s, fetch(message, :content), time&.to_s])))
        end

        # Every String in +value+ as Session#to_h saves it (UTF-8, invalid
        # bytes as "?"); symbol keys stay symbols (JSON writes them alike).
        def scrub(value)
          case value
          when String
            text = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
            text.valid_encoding? ? text : text.scrub("?")
          when Array then value.map { |item| scrub(item) }
          when Hash then value.to_h { |key, item| [key, scrub(item)] }
          when Symbol then value.to_s
          else value
          end
        end

        # The session folder's lines, oldest first (unreadable, torn and
        # unknown lines skipped), cached by the file's path, size and mtime
        # (chi web reads it on each full show).
        # @return [Array<Line>]
        def read(session_dir)
          path = File.join(session_dir, FILE)
          stat = File.stat(path)
          key = [stat.size, stat.mtime.to_r]
          cached = cache_mutex.synchronize { cache[path] }
          return cached[1] if cached && cached[0] == key

          lines = parse(File.binread(path))
          cache_mutex.synchronize do
            cache.shift while cache.size >= CACHE_SIZE
            cache[path] = [key, lines]
          end
          lines
        rescue SystemCallError, IOError
          []
        end

        # @return [Array<Line>]
        def parse(text)
          text.dup.force_encoding(Encoding::UTF_8).scrub("?").each_line.filter_map do |raw|
            Line.from_h(JSON.parse(raw))
          rescue JSON::ParserError
            nil
          end
        end

        # The lines that hold against +messages+ (Session messages, symbol
        # or string keys): each one's range still in them with both ends the
        # same; of overlapping ranges and of one turn's lines the newest
        # (last in the file) wins. Ordered by their range.
        # @return [Array<Line>]
        def valid(lines, messages)
          messages = Array(messages)
          kept = []
          lines.reverse_each do |line|
            next unless holds?(line, messages)
            next if kept.any? { |other| other.turn_id == line.turn_id || overlap?(other, line) }

            kept << line
          end
          kept.sort_by(&:from)
        end

        # The lines a show draws the session's finished turns from: pure,
        # over the file's +lines+ (.read) and the session's +messages+. Today
        # the valid ones (.valid); the turns no valid line covers draw from
        # their messages (H3: a drawing made from them takes their place).
        # @return [Array<Line>] ordered by their range
        def cover(lines, messages) = valid(lines, messages)

        # The last parseable line of +path+, or nil.
        # @return [Line, nil]
        def tail_line(path)
          return nil unless File.file?(path)

          File.open(path, "rb") do |file|
            size = file.size
            chunk = file.pread([size, TAIL_BYTES].min, [size - TAIL_BYTES, 0].max)
            parse(chunk.to_s).last
          end
        rescue SystemCallError, IOError
          nil
        end

        # Whether +line+ is small enough to send in a snapshot: within what
        # #tail_line reads back after a restart (TAIL_BYTES), so a join draws
        # a turn the same before and after one (a bigger line: rebuilt).
        def sendable?(line) = JSON.generate(line.to_h).bytesize <= TAIL_BYTES

        def holds?(line, messages)
          messages.size >= line.to && digest(messages[line.from]) == line.from_digest &&
            digest(messages[line.to - 1]) == line.to_digest
        end

        def overlap?(one, other) = one.from < other.to && other.from < one.to

        private

        def fetch(message, key)
          message.key?(key) ? message[key] : message[key.to_s]
        end

        def cache = (@cache ||= {})
        def cache_mutex = (@cache_mutex ||= Mutex.new)
      end

      # Sessions whose parsed file chi web keeps (a long one's is tens of MB
      # of objects; the mtime moves at every turn end anyway).
      CACHE_SIZE = 8
      # Read from the end at start (#last): a drawing is a few KB, its outputs cut.
      TAIL_BYTES = 1024 * 1024
      private_constant :CACHE_SIZE, :TAIL_BYTES
    end
  end
end
