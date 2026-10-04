# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"

module Samagotchi
  # The thinking a session would otherwise lose: a SessionObserver
  # subscriber (next to SessionMetrics) that keeps the tail of a generation
  # cut mid-stream (a plugin's stop_generation, loop-guard's cut, a steer's
  # cut), stopped with its turn by a plugin (stop_turn), or ended at the
  # provider's output cap (finish_reason length). A cut generation's
  # thinking is dropped from the conversation, and a looping one is what a
  # fixture needs.
  #
  # The tails go to <session dir>/thinking_tails.jsonl, one JSON record a
  # line, the newest MAX_RECORDS kept: next to the session's analytics.json,
  # so an archived session (and a copied session dir) keeps them. Not in the
  # session's messages (nothing there can reach the model, hooks or the
  # web's reload by accident) and not in the turn records (the live snapshot
  # carries those on every /state frame).
  class ThinkingTails
    FILE = "thinking_tails.jsonl"
    # The last chars of a generation's thinking kept: a loop's cycle and
    # some of its lead-in.
    TAIL_CHARS = 20_000
    MAX_RECORDS = 10

    # @param session_dir [#call] the current session's directory, or nil
    #   (no session yet: nothing is written)
    def initialize(session_dir:, clock: -> { Time.now })
      @session_dir = session_dir
      @clock = clock
      @turn_id = nil
      reset
    end

    # The saved records of +dir+, oldest first (empty without a file).
    # @return [Array<Hash>] string-keyed
    def self.read(dir)
      File.readlines(File.join(dir, FILE), chomp: true).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    def call(event)
      case event[:type]
      when :turn_started then @turn_id = event[:turn_id]
      when :generation_started, :generation_retrying then reset
      when :generation_chunk then add(event[:thinking].to_s)
      when :generation_completed then completed(event)
      when :generation_cancelled
        # A plugin's stop_turn mid-generation; a user's Stop is not kept.
        keep(event, finish_reason: "cancelled", stopped_by: "hook") if event[:reason].to_s == "hook"
      end
    rescue StandardError
      nil
    end

    private

    def reset
      @tail = +""
      @chars = 0
    end

    def add(thinking)
      return if thinking.empty?

      @chars += thinking.length
      @tail << thinking
      @tail = @tail[-TAIL_CHARS..] if @tail.length > 2 * TAIL_CHARS
    end

    def completed(event)
      stopped_by = event[:stopped_by]
      return reset unless stopped_by || event[:finish_reason].to_s == "length"

      keep(event, finish_reason: event[:finish_reason].to_s, stopped_by: stopped_by&.to_s, stop_reason: event[:stop_reason])
    end

    # Writes the record and forgets the generation (the native loop's cut
    # with no retry left reports :generation_cancelled after it too).
    def keep(event, **fields)
      return reset if @chars.zero?

      record = { at: @clock.call.utc.iso8601(3), turn_id: @turn_id, iteration: event[:iteration], **fields,
                 thinking_chars: @chars, tail: @tail.length > TAIL_CHARS ? @tail[-TAIL_CHARS..] : @tail }.compact
      reset
      dir = @session_dir.call
      return unless dir

      FileUtils.mkdir_p(dir)
      lines = self.class.read(dir).last(MAX_RECORDS - 1).map { |kept| JSON.generate(kept) }
      AtomicFile.write(File.join(dir, FILE), (lines + [JSON.generate(record)]).join("\n") << "\n")
    end
  end
end
