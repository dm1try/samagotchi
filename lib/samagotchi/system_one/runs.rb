# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

require_relative "../config"
require_relative "../log"
require_relative "question"
require_relative "runs_store"

module Samagotchi
  module SystemOne
    # The saved asks: one run per System 1 ask (Recording), what was sent and
    # answered, and later lines on it, for a later comparison or fine-tune
    # (docs/system-one.md). A Runs without a store saves nothing. Local only.
    #
    # A run's id is "<judgment>/<uuid>": it carries its judgment, so a later
    # line can find its way with the id alone. Later lines never hold up the
    # caller: a failed one is one warn and a false.
    class Runs
      # What the specs read: lines in memory, by judgment.
      class MemoryStore
        attr_reader :lines, :versions

        def initialize
          @lines = Hash.new { |hash, judgment| hash[judgment] = [] }
          @versions = Hash.new { |hash, judgment| hash[judgment] = [] }
          @mutex = Mutex.new
        end

        def append(judgment, line)
          @mutex.synchronize { @lines[judgment] << line }
          true
        end

        def version(judgment, line)
          @mutex.synchronize do
            @versions[judgment] << line unless @versions[judgment].include?(line)
          end
          true
        end
      end

      # Names core keeps (a first word, as a bundle's scope would be) and the
      # suffix a later replay's runs use: a bundle's judgment takes none.
      RESERVED = Config::RESERVED_JUDGMENTS
      RESERVED_SUFFIX = ".replay"
      # The total the sweep keeps (docs/system-one.md).
      MAX_BYTES = 100 * 1024 * 1024

      # Runs on the state dir +root+ (where the sessions folder sits), saving
      # unless system_one.runs is off.
      def self.in(root)
        new(store: Config.get("system_one.runs").to_s == "off" ? nil : RunsStore.new(root))
      end

      # .in, from the sessions folder.
      def self.for_sessions_dir(sessions_dir) = self.in(File.dirname(sessions_dir))

      # The session sweep: runs past session.retention_days (0: forever), then
      # the oldest over the total cap. Whatever system_one.runs says now.
      # @return [Integer] the day files deleted
      def self.sweep_at(root, days: Config.get("session.retention_days").to_i, max_bytes: MAX_BYTES)
        RunsStore.new(root).sweep(days: days, max_bytes: max_bytes)
      end

      # Explicit `chi sessions delete`: that session's runs and their later
      # lines go, whatever system_one.runs says now.
      def self.purge_session(session_id, sessions_dir:)
        RunsStore.new(File.dirname(sessions_dir)).purge_session(session_id)
      end

      # Whether a bundle may declare +name+ (safe as a folder, not core's).
      def self.declarable?(name)
        text = name.to_s
        text.match?(RunsStore::NAME) && !RESERVED.include?(text.split(".").first) && !text.end_with?(RESERVED_SUFFIX)
      end

      # A new run's id.
      def self.new_id(judgment) = "#{judgment}/#{SecureRandom.uuid}"

      # The judgment a run id carries; nil for anything else (a judgments
      # log's id from before runs, a name that isn't safe as a folder).
      def self.judgment_of(run_id)
        judgment, uuid = run_id.to_s.split("/", 2)
        judgment if judgment.to_s.match?(RunsStore::NAME) && !uuid.to_s.empty?
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

      # @param store [#append, #version, nil] nil: nothing is saved
      def initialize(store: nil)
        @store = store
      end

      def on? = !@store.nil?

      # Save one ask, its questions once per digest pair. Raises what its
      # store raises: Recording holds the one warn.
      # @param id [String] the run's id
      # @param judgment [String] its judgment's name
      # @param questions [Array<Question>] as asked
      # @param fields [Hash] the run's other fields; nil ones are left out
      # @return [Boolean] whether it was saved
      def record(id:, judgment:, questions:, **fields)
        return false unless on?

        digests = self.class.digests(questions)
        wire = questions.to_h { |question| [question.id, question.to_wire] }
        @store.version(judgment, digests.merge("questions" => self.class.scrubbed(wire)))
        @store.append(judgment, { "kind" => "run", "id" => id, "judgment" => judgment, "at" => now }
                                  .merge(digests).merge(self.class.scrubbed(fields.compact)))
      end

      # What the user (or +by+) said about a run.
      # @param value [String] the use's own word
      # @param by [String] who said it
      # @param strength [String, nil] "strong" or "weak", where the use has
      #   the difference
      # @param question [String, nil] the question it answers
      # @return [Boolean] whether it was saved
      def label(run_id, value, by:, strength: nil, question: nil)
        later(run_id, "label", value: value, by: by, strength: strength, question: question)
      end

      # What the use did with the answer: never known when the run is written.
      # @return [Boolean] whether it was saved
      def acted(run_id, what) = later(run_id, "acted", what: what)

      # What the gates said at ask time, which can't be recomputed later.
      # @return [Boolean] whether it was saved
      def gates(run_id, **fields) = later(run_id, "gates", **fields)

      private

      def later(run_id, kind, **fields)
        return false unless on?

        judgment = self.class.judgment_of(run_id)
        return false if judgment.nil?

        @store.append(judgment, { "kind" => kind, "run_id" => run_id.to_s, "at" => now }.merge(self.class.scrubbed(fields.compact)))
      rescue StandardError, SystemStackError => e
        # Qualified: inside SystemOne, the bare Log is SystemOne::Log.
        Samagotchi::Log.warn(:system_one, "system_one_run_line_failed",
                             echo: "[samagotchi:system_one] a #{kind} line wasn't saved: #{e.class}: #{e.message}",
                             judgment: judgment, error: e.class.name)
        false
      end

      def now = Time.now.utc.iso8601(3)
    end
  end
end
