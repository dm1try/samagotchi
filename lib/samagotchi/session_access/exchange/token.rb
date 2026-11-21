# frozen_string_literal: true

require "json"
require_relative "../../session"
require_relative "../../reply_wait/target"

module Samagotchi
  module SessionAccess
    class Exchange
      # A reply wait as one string a thin client carries between two
      # POST …/wait calls: "w1." and the url-safe base64 (no padding) of
      # {s: session_id, t: turn, r: report_turn_id, q: queued, e:
      # ended_before, c: cursor, b: baseline ({messages, question_id,
      # last_turn}) or nil, g: owner_grace}.
      #
      # Unsigned on purpose: every field is one the owner may already put
      # in a POST …/wait body (only the owner's routes take a token);
      # +cursor+ is only compared as a string and never becomes a path, and
      # +turn+ reaches paths only through the ENQUEUED_ID_NAME-guarded
      # helpers (SessionInbox). A token says nothing a body couldn't.
      module Token
        PREFIX = "w1."
        KEYS = %w[s t r q e c b g].freeze
        STRINGS = %w[t r c].freeze
        FLAGS = %w[q e].freeze
        BASELINE_FIELDS = { "messages" => Integer, "question_id" => String, "last_turn" => String }.freeze
        BASELINE_WORDS = "baseline is {messages, question_id, last_turn}"

        # Anything that isn't a token this chi made: its message says what.
        class Invalid < StandardError; end

        module_function

        # @param target [ReplyWait::Target]
        # @return [String]
        def dump(session_id, target)
          fields = { s: session_id, t: target.turn, r: target.report_turn_id, q: target.queued == true,
                     e: target.ended_before == true, c: target.cursor, b: target.baseline&.to_h, g: target.owner_grace }
          PREFIX + [JSON.generate(fields)].pack("m0").tr("+/", "-_").delete("=")
        end

        # @return [Array(String, ReplyWait::Target)] the session id and the wait
        # @raise [Invalid]
        def load(string)
          raise Invalid, "not a wait token" unless string.is_a?(String) && string.start_with?(PREFIX)

          fields = decode(string.delete_prefix(PREFIX))
          raise Invalid, "a wait token names unknown fields" unless (fields.keys - KEYS).empty?

          [session_of(fields["s"]), target_of(fields)]
        end

        # A wait body's or a token's baseline: nil, or a Baseline from
        # exactly its fields, each of its type or null.
        # @return [ReplyWait::Baseline, nil]
        # @raise [Invalid] BASELINE_WORDS
        def baseline(raw)
          return nil if raw.nil?
          unless raw.is_a?(Hash) && raw.all? { |key, value| BASELINE_FIELDS.key?(key) && (value.nil? || value.is_a?(BASELINE_FIELDS[key])) }
            raise Invalid, BASELINE_WORDS
          end

          ReplyWait::Baseline.new(**raw.transform_keys(&:to_sym))
        end

        def decode(text)
          raise Invalid, "a wait token is url-safe base64" unless text.match?(/\A[A-Za-z0-9_-]+\z/)

          padded = text.tr("-_", "+/") + ("=" * ((4 - (text.length % 4)) % 4))
          fields = JSON.parse(padded.unpack1("m0"))
          raise Invalid, "a wait token holds an object" unless fields.is_a?(Hash)

          fields
        rescue ArgumentError, JSON::ParserError
          raise Invalid, "not a wait token"
        end

        def session_of(id)
          raise Invalid, "a wait token names its session" unless id.is_a?(String) && Session.valid_id?(id)

          id
        end

        def target_of(fields)
          STRINGS.each do |key|
            raise Invalid, "a wait token's #{key} is a string" unless fields[key].nil? || fields[key].is_a?(String)
          end
          FLAGS.each do |key|
            raise Invalid, "a wait token's #{key} is true or false" unless [nil, true, false].include?(fields[key])
          end
          grace = fields["g"]
          raise Invalid, "a wait token's g is positive seconds" unless grace.nil? || (grace.is_a?(Numeric) && grace.positive?)

          ReplyWait::Target.new(turn: fields["t"], report_turn_id: fields["r"], queued: fields["q"] == true,
                                ended_before: fields["e"] == true, cursor: fields["c"], baseline: baseline(fields["b"]),
                                owner_grace: grace)
        end
      end
    end
  end
end
