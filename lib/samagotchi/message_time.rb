# frozen_string_literal: true

require "time"

module Samagotchi
  # When a history entry happened: its wall-clock stamp (KEY), and the
  # dividers the UIs print when a quiet gap passes between two entries.
  #
  # The stamp is display-only: no wire format reads it, so the bytes the
  # model gets (and its prompt cache) are the same with or without it. A
  # time the model should read is baked into the message's content when the
  # message is made (ReminderQueue's header), never rendered at wire time.
  #
  # Everything here is a pure function of the times passed in; the one wall
  # clock is #now (a seam the specs pin to a fixed time).
  module MessageTime
    # The history entry key: a local-offset ISO 8601 time with milliseconds.
    KEY = :at
    # The quiet time after which the UIs mark a gap.
    GAP_SECONDS = 600

    DEFAULT_SOURCE = -> { Time.now }
    private_constant :DEFAULT_SOURCE

    class << self
      # The wall clock: a callable returning a Time (nil: Time.now).
      attr_writer :source

      # @return [Time] now, by the wall clock seam
      def now = (@source || DEFAULT_SOURCE).call

      # Back to Time.now.
      def reset! = @source = nil
    end

    module_function

    # @param time [Time]
    # @return [String] the stamp's text
    def iso(time) = time.iso8601(3)

    # The stamp of an ISO text from elsewhere (a note's created_at), or nil
    # when it doesn't parse.
    def iso_of(text)
      text && iso(Time.iso8601(text.to_s))
    rescue ArgumentError
      nil
    end

    # +message+ with KEY set to +time+'s stamp, unless it has one already
    # (a Symbol- or String-keyed message). Changes +message+ and returns it.
    def stamp(message, time)
      return message if message.key?(KEY) || message.key?(KEY.to_s)

      message[KEY] = time.is_a?(String) ? time : iso(time)
      message
    end

    # @return [String, nil] the stamp of +message+ (Symbol or String keys)
    def of(message)
      return nil unless message.is_a?(Hash)

      message[KEY] || message[KEY.to_s]
    end

    # @return [String, nil] "14:32", local time
    def clock(iso) = local(iso)&.strftime("%H:%M")

    # @return [String, nil] "Sat 24 Oct 09:10", local time
    def day_clock(iso) = local(iso)&.strftime("%a %-d %b %H:%M")

    # The divider between activity that ended at +prev_iso+ and activity
    # starting at +cur_iso+: nil below GAP_SECONDS (or when either time is
    # unknown), else "── 14:32 · 47 min later ──", the date added when the
    # local day changed.
    def gap_line(prev_iso, cur_iso)
      prev = local(prev_iso)
      cur = local(cur_iso)
      return nil unless prev && cur

      seconds = cur - prev
      return nil if seconds < GAP_SECONDS

      time = prev.to_date == cur.to_date ? cur.strftime("%H:%M") : cur.strftime("%a %-d %b %H:%M")
      "── #{time} · #{ago(seconds)} later ──"
    end

    # @return [String] "47 min", "3 h", "2 d" (whole units, rounded down;
    #   the web's relativeTime scale)
    def ago(seconds)
      seconds = seconds.to_f
      return "#{[(seconds / 60).floor, 0].max} min" if seconds < 3600
      return "#{(seconds / 3600).floor} h" if seconds < 86_400

      "#{(seconds / 86_400).floor} d"
    end

    def local(iso)
      iso && Time.iso8601(iso.to_s).localtime
    rescue ArgumentError
      nil
    end
  end
end
