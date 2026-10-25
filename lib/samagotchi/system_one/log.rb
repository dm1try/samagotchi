# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "../log"

module Samagotchi
  module SystemOne
    # The judgments log: one JSON line per System 1 judgment, and a later
    # line for the user's answer to the ask it judged (docs/guardrails.md,
    # "System 1"). It sits beside the approvals store,
    # `$XDG_STATE_HOME/samagotchi/guardrails/judgments.jsonl`, and is written
    # append-only under an exclusive flock: several workers judge at once,
    # and a line is never rewritten to add its label. Past 5 MB the file is
    # rewritten, under the same lock, keeping the newest half of its lines.
    #
    # Nothing here can break an approval: every write that fails is one
    # Log.warn and a nil, and the ask reaches the user as it would have.
    class Log
      FILE = "judgments.jsonl"
      # Above this the file is rewritten keeping the newest half of the lines.
      MAX_BYTES = 5 * 1024 * 1024
      MODE = 0o600
      # What a label's answer can be (P2a writes the first four;
      # "should_have_asked" comes with `/guardrails wrong`).
      ANSWERS = %w[allow_once allow_wide deny none should_have_asked].freeze

      attr_reader :dir, :path

      # @param dir [String] the guardrails store dir (Guardrails::Approvals.dir_for)
      # @param warn [#call] (reason) — the record for a failed write
      def initialize(dir:, warn: nil)
        @dir = dir
        @path = File.join(dir, FILE)
        @warn = warn || ->(reason) { Samagotchi::Log.warn(:guardrails, "system_one_log_failed", echo: "[samagotchi:guardrails] #{reason}") }
      end

      # @param fields [Hash] the judgment's own fields (rule, tool, p, …)
      # @return [String, nil] the judgment's id, nil when nothing was written
      def judgment(fields)
        id = SecureRandom.uuid
        append({ "kind" => "judgment", "id" => id, "at" => Time.now.utc.iso8601 }.merge(fields)) ? id : nil
      end

      # @param id [String] a judgment's id
      # @param answer [String] one of ANSWERS
      # @return [Boolean] whether the line was written
      def label(id, answer)
        return false if id.to_s.strip.empty?

        append({ "kind" => "label", "id" => id.to_s, "at" => Time.now.utc.iso8601, "answer" => answer.to_s })
      end

      # The judgments, oldest first, each joined with its LAST label
      # (answer: nil when it has none). Lines that don't parse are skipped;
      # labels of a judgment that isn't there are dropped.
      # @return [Array<Hash>]
      def entries
        judgments = {}
        labels = {}
        with_lock(File::LOCK_SH) do |file|
          file.each_line do |line|
            data = parse(line)
            next if data.nil?

            case data["kind"]
            when "judgment" then judgments[data["id"]] = data
            when "label" then labels[data["id"]] = data["answer"] if data.key?("id")
            end
          end
        end
        judgments.map { |id, judgment| judgment.merge("answer" => labels[id]) }
      rescue StandardError => e
        warn_about(e)
        []
      end

      private

      def append(line)
        with_lock(File::LOCK_EX) do |file|
          # The handle is read-write (not O_APPEND) so #trim can rewrite the
          # file: write at the end, under the lock nobody else holds.
          file.seek(file.size)
          file.puts(JSON.generate(line))
          trim(file)
        end
        true
      rescue StandardError => e
        warn_about(e)
        false
      end

      # @param mode [Integer] File::LOCK_EX for a write, LOCK_SH to read
      def with_lock(mode)
        FileUtils.mkdir_p(@dir)
        File.open(@path, File::RDWR | File::CREAT, MODE) do |file|
          file.flock(mode)
          yield file
        end
      end

      # Past MAX_BYTES, keep the newest half of the lines (whole, so a
      # judgment and its labels stay together as far as the cut reaches).
      def trim(file)
        file.flush
        return if file.size <= MAX_BYTES

        file.rewind
        lines = file.readlines
        keep = lines.last([lines.size / 2, 1].max).join
        file.rewind
        file.write(keep)
        file.flush
        file.truncate(keep.bytesize)
      end

      def parse(line)
        data = JSON.parse(line)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def warn_about(error)
        @warn.call("system one log: #{path}: #{error.class}: #{error.message}")
      end
    end
  end
end
