# frozen_string_literal: true

require_relative "../message_time"

module Samagotchi
  class TerminalUI
    # When the session's last activity was, for both TUIs' gap dividers: a
    # dim "── 14:32 · 47 min later ──" before what comes after a quiet
    # MessageTime::GAP_SECONDS. Activity is a prompt (typed or another
    # client's), a reminder, a context note, a recap, and a turn's end; a
    # gap is measured from the end of one to the start of the next, so a
    # long turn followed at once by another marks nothing.
    #
    # The times are this terminal's wall clock when it saw them (+now+),
    # seeded at the join from the session's stamped history. Read from the
    # reader thread too (a typed prompt's divider goes above its echo), so
    # every read-and-mark is under one lock.
    class GapClock
      # @param now [#call] the wall clock (a Time); MessageTime.now, which
      #   the specs pin, by default
      def initialize(now: -> { MessageTime.now })
        @now = now
        @last = nil
        @lock = Mutex.new
      end

      # @return [String] now, as a stamp
      def now_iso = MessageTime.iso(@now.call)

      # Mark activity starting now.
      # @param quiet [Boolean] mark only, no divider (a turn runs: its own
      #   steps are no gap)
      # @return [String, nil] the divider's text when a gap passed since
      #   the last activity
      def divider(quiet: false)
        @lock.synchronize do
          now = now_iso
          line = quiet ? nil : MessageTime.gap_line(@last, now)
          @last = now
          line
        end
      end

      # Mark activity (a turn's end) without a divider.
      def touch = divider(quiet: true)

      # Start from the session's last activity (the join, a resume): the
      # newest stamp in +messages+ (Symbol- or String-keyed), else
      # +fallback+ (a saved recap's created_at). Nothing known: nothing set.
      # @return [String, nil] the time it started from
      def seed(messages, fallback: nil)
        iso = Array(messages).reverse_each.lazy.filter_map { |m| MessageTime.of(m) }.first || fallback
        iso = MessageTime.iso_of(iso)
        @lock.synchronize { @last = iso } if iso
        iso
      end

      # The join's line when the last activity is a gap ago:
      # "── last activity 14:32 · 47 min ago ──" (the date when the local
      # day changed). Printed, it stands for the gap: the clock moves to now,
      # so the next prompt marks none.
      # @return [String, nil]
      def join_line
        @lock.synchronize do
          now = now_iso
          next nil unless MessageTime.gap_line(@last, now)

          last = Time.iso8601(@last).localtime
          same_day = last.to_date == Time.iso8601(now).localtime.to_date
          time = same_day ? MessageTime.clock(@last) : MessageTime.day_clock(@last)
          line = "── last activity #{time} · #{MessageTime.ago(Time.iso8601(now) - last)} ago ──"
          @last = now
          line
        end
      end
    end
  end
end
