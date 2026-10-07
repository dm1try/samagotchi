# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "../paths"

module Samagotchi
  module Broadcast
    # What each broadcast decided, one JSON line per broadcast in
    # <state>/samagotchi/broadcast/log.jsonl: its id, time, note text, the
    # note's tags and every recipient's verdict (no scope cards: they quote
    # the user's prompts). `chi broadcast deliver` adds a "corrected" line
    # for the sessions it delivered to anyway: labels for the threshold and
    # a future classifier. Not a list sessions read: broadcasts stay
    # fire-and-forget. Over MAX_BYTES the file becomes log.jsonl.1 (one old
    # file kept).
    class TriageLog
      MAX_BYTES = 2 * 1024 * 1024

      # One recipient's line in a broadcast.
      # @!attribute result [String] "delivered", "skipped" or "failed"
      # @!attribute p [Float, nil] the triage model's P(yes), nil when no
      #   model judged it
      # @!attribute by [String] Triage::Verdict#by
      # @!attribute tags [Array<String>] the session's tags (Tag#label)
      Entry = Data.define(:session, :result, :p, :reason, :by, :tags)

      # A `chi broadcast deliver`: when, and each session's result.
      # @!attribute sessions [Array<Delivery>]
      Correction = Data.define(:at, :sessions)

      # One session a correction delivered to (or tried).
      Delivery = Data.define(:session, :result)

      # A broadcast as read back, with the corrections made to it since.
      # @!attribute at [Time]
      # @!attribute recipients [Array<Entry>]
      # @!attribute corrections [Array<Correction>]
      Record = Data.define(:id, :at, :text, :note_tags, :triage_model, :recipients, :corrections) do
        # @return [Entry, nil]
        def entry(session) = recipients.find { |e| e.session == session }

        # Whether +session+ got it, from the broadcast or a correction.
        def delivered?(session)
          entry(session)&.result == "delivered" ||
            corrections.any? { |c| c.sessions.any? { |d| d.session == session && d.result == "delivered" } }
        end

        def to_json_hash
          { id: id, at: at.iso8601, text: text, note_tags: note_tags, triage_model: triage_model,
            recipients: recipients.map(&:to_h),
            corrections: corrections.map { |c| { at: c.at.iso8601, sessions: c.sessions.map(&:to_h) } } }
        end
      end

      # No broadcast with that id, or several start with it.
      class NotFound < StandardError; end

      # @return [String] <state>/samagotchi/broadcast/log.jsonl
      def self.default_path(env: ENV) = File.join(Paths.state_dir(env: env), "broadcast", "log.jsonl")

      attr_reader :path

      def initialize(path = self.class.default_path)
        @path = path
      end

      # @param at [Time]
      # @param recipients [Array<Entry>]
      def append_broadcast(id:, at:, text:, note_tags:, triage_model:, recipients:)
        append(type: "broadcast", id: id, at: at.iso8601, text: text, note_tags: note_tags, triage_model: triage_model,
               recipients: recipients.map(&:to_h))
      end

      # @param sessions [Array<Delivery>]
      def append_correction(id:, at:, sessions:)
        append(type: "corrected", id: id, at: at.iso8601, sessions: sessions.map(&:to_h))
      end

      # Every broadcast in the log (the rotated file's first), oldest
      # first, with its corrections. A line that doesn't parse is skipped.
      # @return [Array<Record>]
      def records
        found = {}
        [rotated_path, @path].each do |file|
          next unless File.file?(file)

          File.foreach(file) do |line|
            data = parse(line)
            next unless data

            if data["type"] == "broadcast"
              found[data["id"]] = record(data)
            elsif data["type"] == "corrected" && (previous = found[data["id"]])
              found[data["id"]] = previous.with(corrections: previous.corrections + [correction(data)])
            end
          end
        end
        found.values
      end

      # The broadcast +given+ names: its id, with or without "b-", or the
      # start of one.
      # @return [Record]
      # @raise [NotFound]
      def find(given)
        want = given.to_s.strip.delete_prefix("b-")
        raise NotFound, "no broadcast id given" if want.empty?

        matches = records.select { |r| r.id.delete_prefix("b-").start_with?(want) }
        return matches.first if matches.one?
        raise NotFound, "no broadcast #{given} in the log (chi broadcast log)" if matches.empty?

        raise NotFound, "#{given} names #{matches.size} broadcasts (#{matches.map(&:id).join(", ")}); give more of the id"
      end

      private

      def rotated_path = "#{@path}.1"

      def append(data)
        FileUtils.mkdir_p(File.dirname(@path))
        File.rename(@path, rotated_path) if File.file?(@path) && File.size(@path) > MAX_BYTES
        File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          file.write("#{JSON.generate(data)}\n")
        end
      end

      def parse(line)
        data = JSON.parse(line)
        data.is_a?(Hash) && data["id"].is_a?(String) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def record(data)
        Record.new(id: data["id"], at: time(data["at"]), text: data["text"].to_s, note_tags: Array(data["note_tags"]),
                   triage_model: data["triage_model"],
                   recipients: Array(data["recipients"]).filter_map { |e| entry(e) }, corrections: [])
      end

      def entry(data)
        return nil unless data.is_a?(Hash)

        Entry.new(session: data["session"].to_s, result: data["result"].to_s, p: data["p"], reason: data["reason"].to_s,
                  by: data["by"].to_s, tags: Array(data["tags"]))
      end

      def correction(data)
        sessions = Array(data["sessions"]).filter_map do |d|
          Delivery.new(session: d["session"].to_s, result: d["result"].to_s) if d.is_a?(Hash)
        end
        Correction.new(at: time(data["at"]), sessions: sessions)
      end

      def time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        Time.at(0)
      end
    end
  end
end
