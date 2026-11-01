# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

require_relative "question"

module Samagotchi
  module SystemOne
    # The saved asks: one run per System 1 ask (Recording), what was sent and
    # answered, for a later comparison or fine-tune (docs/system-one.md).
    # A Runs without a store saves nothing.
    #
    # A run's id is "<judgment>/<uuid>": it carries its judgment, so a later
    # line can find its way with the id alone.
    class Runs
      # What the specs read: lines in memory, by judgment.
      class MemoryStore
        attr_reader :lines

        def initialize
          @lines = Hash.new { |hash, judgment| hash[judgment] = [] }
          @mutex = Mutex.new
        end

        def append(judgment, line)
          @mutex.synchronize { @lines[judgment] << line }
          true
        end
      end

      # @param store [#append, nil] nil: nothing is saved
      def initialize(store: nil)
        @store = store
      end

      # A new run's id.
      def self.new_id(judgment) = "#{judgment}/#{SecureRandom.uuid}"

      # The judgment a run id carries; nil for anything else (a judgments
      # log's id from before runs).
      def self.judgment_of(run_id)
        judgment, uuid = run_id.to_s.split("/", 2)
        judgment unless judgment.to_s.empty? || uuid.to_s.empty?
      end

      # The digests a run groups by: the questions' wording and, apart, their
      # criteria, which can vary per session (a toolkit's kits).
      # @param questions [Array<Question>]
      # @return [Hash{String => String}]
      def self.digests(questions)
        wording = questions.map { |question| [question.id, question.type.to_s, question.instructions] }
        criteria = questions.map { |question| [question.id, question.criteria] }
        { "instructions_digest" => digest(wording), "criteria_digest" => digest(criteria) }
      end

      def self.digest(value) = Digest::SHA256.hexdigest(JSON.generate(value))[0, 16]
      private_class_method :digest

      # A copy +value+ can be written as JSON from: bytes that aren't UTF-8
      # (a command's output in a state) are replaced, in strings and keys.
      def self.scrubbed(value)
        case value
        when String then value.dup.force_encoding(Encoding::UTF_8).scrub("�")
        when Symbol then scrubbed(value.to_s)
        when Hash then value.to_h { |key, item| [scrubbed(key.to_s), scrubbed(item)] }
        when Array then value.map { |item| scrubbed(item) }
        else value
        end
      end

      def on? = !@store.nil?

      # Save one ask. Raises what its store raises: Recording holds the one
      # warn.
      # @param id [String] the run's id
      # @param judgment [String] its judgment's name
      # @param questions [Array<Question>] as asked
      # @param fields [Hash] the run's other fields; nil ones are left out
      # @return [Boolean] whether it was saved
      def record(id:, judgment:, questions:, **fields)
        return false unless on?

        line = { "kind" => "run", "id" => id, "judgment" => judgment, "at" => Time.now.utc.iso8601(3) }
               .merge(self.class.digests(questions))
               .merge(self.class.scrubbed(fields.compact))
        @store.append(judgment, line)
      end
    end
  end
end
