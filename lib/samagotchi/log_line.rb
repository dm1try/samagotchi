# frozen_string_literal: true

require "json"
require "time"

module Samagotchi
  # The debug log's line format: the one contract between the writer (Log)
  # and every reader (the web's later log view, `chi log`, grep and awk).
  #
  #   <ts> <LEVEL> <tag> pid=<n> [sid=<8>] <event> [k=v ...]
  #       <payload line>
  #
  # ts is UTC ISO8601 with milliseconds, LEVEL is padded to 5, tag and event
  # are slugs. A value is bare when it has no space, quote or `=`, else a
  # JSON string, so a newline in a value never splits a record. Payload lines
  # (debug dumps) are indented by four spaces and belong to the record above.
  module LogLine
    LEVELS = %w[DEBUG INFO WARN ERROR].freeze
    TAGS = %w[turn http worker bridge web attached repl idle recap hooks plugins guardrails config memory model context].freeze
    INDENT = "    "

    Record = Struct.new(:ts, :level, :tag, :pid, :sid, :event, :fields, :payload, keyword_init: true)

    SLUG = /\A[a-z0-9_.-]+\z/
    KEY = /\A[a-z0-9_]+\z/
    BARE = /\A[^"=\p{Z}\p{Cc}\p{Cf}]+\z/
    HEADER = /\A(?<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z) (?<level>DEBUG|INFO|WARN|ERROR) +(?<tag>[a-z]+) pid=(?<pid>\d+)(?: sid=(?<sid>[^\s"=]+))? (?<event>[a-z0-9_.-]+)(?<rest>.*)\z/
    FIELD = /\G (?<key>[a-z0-9_]+)=(?:"(?<quoted>(?:[^"\\]|\\.)*)"|(?<bare>[^\s"=]+))/
    # C1 controls and the line/paragraph separators JSON.generate leaves as is.
    EXTRA_ESCAPES = /[\u007f-\u009f\u2028\u2029]/

    module_function

    # The record as one string: header, payload lines, trailing newline.
    def format(record)
      head = [format_ts(record.ts), record.level.to_s.upcase.ljust(5), record.tag.to_s, "pid=#{record.pid}"]
      head << "sid=#{record.sid}" if record.sid && !record.sid.to_s.empty?
      head << record.event.to_s
      line = +head.join(" ")
      (record.fields || {}).each { |key, value| line << " #{key}=#{format_value(value)}" unless value.nil? }
      line << "\n"
      payload = record.payload
      line << format_payload(payload) if payload && !payload.to_s.empty?
      line
    end

    def format_ts(time)
      return time if time.is_a?(String)

      time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    def format_value(value)
      text = clean(value.to_s)
      return text if text.match?(BARE)

      JSON.generate(text).gsub(EXTRA_ESCAPES) { |c| Kernel.format("\\u%04x", c.ord) }
    end

    # Every payload line indented; control characters (ANSI colours from a
    # tool, a stray \r) shown escaped so the log can be cat'ed safely.
    def format_payload(payload)
      clean(payload.to_s).split("\n", -1).map { |line| "#{INDENT}#{escape_controls(line.chomp("\r"))}\n" }.join
    end

    def escape_controls(text)
      text.gsub(/[\p{Cc}&&[^\t]]|#{EXTRA_ESCAPES}/o) { |c| c == "\e" ? "\\e" : Kernel.format("\\u%04x", c.ord) }
    end

    # Valid UTF-8 whatever the source (binary tool output included).
    def clean(text)
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text.valid_encoding? ? text : text.scrub("?")
    end

    # One header line → Record (payload nil), or nil when it isn't one.
    def parse(line)
      match = HEADER.match(line.to_s.chomp)
      return nil unless match

      fields = parse_fields(match[:rest])
      return nil unless fields

      Record.new(ts: match[:ts], level: match[:level], tag: match[:tag], pid: Integer(match[:pid]),
                 sid: match[:sid], event: match[:event], fields: fields, payload: nil)
    end

    def parse_fields(rest)
      fields = {}
      pos = 0
      while pos < rest.length
        m = FIELD.match(rest, pos)
        return nil unless m && m.begin(0) == pos

        fields[m[:key]] = m[:quoted] ? JSON.parse("[\"#{m[:quoted]}\"]").first : m[:bare]
        pos = m.end(0)
      end
      fields
    rescue JSON::ParserError
      nil
    end

    def payload_line?(line)
      line.start_with?(INDENT)
    end

    # Yields each Record of a log (payload lines joined onto theirs). Lines
    # that are neither (an older format, a torn write) go to on_invalid.
    def each_record(io, on_invalid: nil)
      return enum_for(:each_record, io, on_invalid: on_invalid) unless block_given?

      current = nil
      io.each_line do |raw|
        line = clean(raw).chomp
        if current && payload_line?(line)
          text = line.delete_prefix(INDENT)
          current.payload = current.payload ? "#{current.payload}\n#{text}" : text
          next
        end
        yield current if current
        current = parse(line)
        on_invalid&.call(line) if current.nil? && !line.empty?
      end
      yield current if current
    end
  end
end
