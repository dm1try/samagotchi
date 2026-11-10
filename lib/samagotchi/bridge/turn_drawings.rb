# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "../log"
require_relative "../message_time"
require_relative "../context_note"
require_relative "../degrade"
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
    # Both read TurnDrawings at load: loaded on first use (no require cycle).
    autoload :TurnRanges, File.expand_path("turn_ranges", __dir__)

    class TurnDrawings
      autoload :Synth, File.expand_path("turn_drawings/synth", __dir__)

      FILE = "turn_drawings.jsonl"
      # In the sidecar's features (Bridge::FEATURES): this worker's CardStore
      # lists an in-turn entry's of_turn, which a page drawing the turn needs
      # to leave that entry to the drawing. chi web draws no drawings for a
      # live worker without it (an older one: its rows would show twice).
      FEATURE = "turn_drawings"
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
            cache.delete(path)
            cache.shift while !cache.empty? && (cache.size >= CACHE_SIZE || cache.sum { |_, (k, _)| k[0] } + stat.size > CACHE_BYTES)
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
        # over the file's +lines+ (.read) and the session's +messages+. The
        # valid ones (.valid), and for each turn (TurnRanges) no valid line
        # overlaps, a line made from its messages (Synth, memoized per
        # range), so every finished turn has one. +timing+: the session's
        # records (turn_records, tool_records: the show's timing payload);
        # +entries+: CardStore's listed entries (the show's cards);
        # +skip_turn_id+: the running turn's id (its messages may be in
        # while its line isn't written yet: never synthesized). A file whose
        # lines can't be checked counts as none: every turn synthesized.
        # @return [Array<Line>] ordered by their range
        def cover(lines, messages, timing: nil, entries: [], skip_turn_id: nil, session_id: nil, cwd: nil)
          messages = Array(messages)
          real = Degrade.call(:web, "turn_drawings_unreadable", fallback: []) { valid(lines, messages) }
          ranges = TurnRanges.of(messages)
          open = uncovered(ranges, real)
          ranges = reserve_ids(ranges, open, real)
          turn_records = list_of(timing, :turn_records)
          records = TurnRanges.records(ranges, turn_records)
          tools = list_of(timing, :tool_records).group_by { |t| field(t, :turn_id) }
          own = Array(entries).select { |e| e.is_a?(Hash) && field(e, :of_turn) }.group_by { |e| field(e, :of_turn) }
          made = open.filter_map do |i|
            range = ranges[i]
            next if skip_turn_id && range.turn_id == skip_turn_id

            record = records[i]
            # The turn's tool records by its record's id, else its own (a
            # record lost, its tool records saved: the TUI's join does so too).
            tool_id = record ? field(record, :id) : (range.turn_id if range.own_id?)
            Synth.memoized(session_id, messages, range, record: record, tools: tool_id ? tools.fetch(tool_id, []) : [],
                                                        entries: own.fetch(range.turn_id, []), cwd: cwd)
          end
          (real + made).sort_by(&:from)
        end

        # +ranges+ with each one to be made (+open+, indexes) whose id a kept
        # line has (a failed turn's kept steps, then its re-run under the same
        # turn id: .valid keeps the newest line for an id) renamed "<id>~<from>":
        # never two lines with one id (the page would draw them as one turn),
        # and not its turn's own (no end turn_id, record or entries).
        def reserve_ids(ranges, open, lines)
          taken = lines.to_set(&:turn_id)
          return ranges if taken.empty?

          made = open.to_set
          ranges.each_with_index.map do |range, i|
            made.include?(i) && taken.include?(range.id) ? range.with(id: "#{range.id}~#{range.from}") : range
          end
        end
        private :reserve_ids

        # The indexes of +ranges+ no line of +lines+ (sorted by from, apart)
        # overlaps: one walk over both.
        def uncovered(ranges, lines)
          at = 0
          ranges.each_index.reject do |i|
            range = ranges[i]
            at += 1 while at < lines.size && lines[at].to >= 0 && lines[at].to <= range.from
            at < lines.size && lines[at].from < range.to
          end
        end
        private :uncovered

        # A fork's drawings (Plugin::Sessions#fork, before its child's worker
        # spawns: no other writer): the lines of +from_dir+'s file that hold
        # against the child's seed +messages+ (same indices, same ends; a range
        # whose end the image copy changed doesn't), written as the child's
        # file. A seed without the system head (a plugin's ctx.messages) is
        # read as the child's messages will be once its first turn puts the
        # head back at index 0 (ContextNote.with_system_head): the lines keep
        # the parent's indices, and hold from then on. Its other turns are
        # made from their messages at read.
        # @return [Integer] the lines carried
        def carry(from_dir:, to_dir:, messages:)
          seed = Array(messages)
          seed = [{ role: "system", content: "" }] + seed unless ContextNote.system_head?(seed.first)
          lines = valid(read(from_dir), seed)
          return 0 if lines.empty?

          FileUtils.mkdir_p(to_dir)
          File.write(File.join(to_dir, FILE), lines.map { |line| "#{JSON.generate(line.to_h)}\n" }.join, perm: 0o600)
          lines.size
        end

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

        def field(hash, key) = hash.is_a?(Hash) ? fetch(hash, key) : nil

        def list_of(timing, key) = Array(timing.is_a?(Hash) ? fetch(timing, key) : nil).grep(Hash)

        def cache = (@cache ||= {})
        def cache_mutex = (@cache_mutex ||= Mutex.new)
      end

      # Sessions whose parsed file chi web keeps (a long one's is tens of MB
      # of objects; the mtime moves at every turn end anyway), and the files'
      # bytes they may sum to (the newest one is always kept). Both bound the
      # files' and lines' JSON bytes, not the heap: parsed lines take several
      # times that (as Synth::MEMO_BYTES does).
      CACHE_SIZE = 8
      CACHE_BYTES = 64 * 1024 * 1024
      # Read from the end at start (#last): a drawing is a few KB, its outputs cut.
      TAIL_BYTES = 1024 * 1024
      private_constant :CACHE_SIZE, :CACHE_BYTES, :TAIL_BYTES
    end
  end
end
