# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../atomic_file"
require_relative "../session"
require_relative "../reply_wait"

module Samagotchi
  module Tools
    # What a parent was already told about one delegate child: the newest
    # reply it was given (+reply_file+, ReplyWait's cursor) and the child as
    # it was then (+messages+, +question_id+, +last_turn+: ReplyWait's
    # baseline). nil +messages+ means no baseline. +turn+: the enqueued_id
    # of the child's turn the last follow-up went to (Delegate.follow_up),
    # whose own reply a wait takes (ReplyWait's turn:); nil once that turn
    # was reported, or when unknown (a new child, an older worker).
    #   +report_claim+: a report reserved until the parent's turn is settled
    # (ReportClaim).
    DelegateCursor = Data.define(:reply_file, :last_turn, :question_id, :messages, :turn, :report_claim) do
      def initialize(reply_file: nil, last_turn: nil, question_id: nil, messages: nil, turn: nil, report_claim: nil) = super

      def self.empty = new

      # The cursor with no report reserved: what it is once the reserving
      # turn is settled, and how two cursors compare apart from a claim.
      def without_claim = with(report_claim: nil)

      # @param baseline [ReplyWait::Baseline, nil] ReplyWait.baseline_of's
      def with_baseline(baseline)
        with(messages: baseline&.messages, question_id: baseline&.question_id, last_turn: baseline&.last_turn)
      end

      # @return [ReplyWait::Baseline, nil] ReplyWait's baseline:, nil when
      #   none was taken
      def baseline
        return nil if messages.nil?

        ReplyWait::Baseline.new(messages: messages, question_id: question_id, last_turn: last_turn)
      end

      def to_json_hash = to_h.merge(report_claim: report_claim&.to_json_hash).transform_keys(&:to_s).compact

      def self.from_json_hash(data)
        return empty unless data.is_a?(Hash)

        new(reply_file: data["reply_file"], last_turn: data["last_turn"], question_id: data["question_id"],
            messages: data["messages"], turn: data["turn"], report_claim: ReportClaim.from_json_hash(data["report_claim"]))
      end
    end

    # A delegate report reserved in the parent's cursor (ChildReports) until
    # the parent's turn that took it is kept or rolled back: +id+ the
    # claim's id (the taking turn's Report#claim_id), +file+ the reply file
    # reported (nil for a question), +cursor+ the DelegateCursor the report
    # moves the parent to once kept (its own claim empty). In delegates.json
    # it is {"id", "file", "cursor"}, the file's key kept even when nil.
    ReportClaim = Data.define(:id, :file, :cursor) do
      def to_json_hash = { "id" => id, "file" => file, "cursor" => cursor.to_json_hash }

      # @return [ReportClaim, nil] nil for no claim (or not a Hash)
      def self.from_json_hash(data)
        return nil unless data.is_a?(Hash)

        new(id: data["id"], file: data["file"], cursor: DelegateCursor.from_json_hash(data["cursor"]))
      end
    end

    # The parent's cursors, one per child, in <parent dir>/delegates.json, so
    # a respawned worker (or a REPL resuming the session) doesn't hand the
    # model a reply it already had. Written by whoever owns the parent (its
    # worker, or the REPL its kernel runs in), and by a continue moving
    # delegates to the chain's new link (ChildMove, from another process):
    # a Mutex for the owner's turn thread vs its loop thread, and a flock on
    # LOCK_FILE between processes; the file is replaced whole.
    module DelegateCursors
      FILE = "delegates.json"
      LOCK_FILE = "delegates.lock"
      LOCK = Mutex.new

      module_function

      # @return [DelegateCursor] the child's cursor, empty when none
      def get(parent_id, child_id, state_dir:)
        get_from(read(parent_id, state_dir: state_dir), child_id)
      end

      # Read, change and write one child's cursor under the lock.
      # @yieldparam cursor [DelegateCursor]
      # @yieldreturn [DelegateCursor]
      # @return [DelegateCursor] the new cursor
      def update(parent_id, child_id, state_dir:)
        locked(parent_id, state_dir: state_dir) do
          all = read(parent_id, state_dir: state_dir)
          cursor = yield get_from(all, child_id)
          all[child_id] = cursor.to_json_hash
          write(parent_id, all, state_dir: state_dir)
          cursor
        end
      end

      # Reserve a report only if the cursor read to build it is still current.
      # @param claim [ReportClaim]
      # @return [DelegateCursor, nil] the reserved cursor, or nil if another path moved it
      def claim_report(parent_id, child_id, expected:, claim:, state_dir:)
        locked(parent_id, state_dir: state_dir) do
          all = read(parent_id, state_dir: state_dir)
          cursor = get_from(all, child_id)
          next nil unless cursor == expected

          claimed = cursor.with(report_claim: claim)
          all[child_id] = claimed.to_json_hash
          write(parent_id, all, state_dir: state_dir)
          claimed
        end
      end

      # A new owner can retry reports left reserved by a worker that exited
      # before committing or releasing its turn. No cursor file means no
      # claims: the lock would create the session dir and its lock file, so
      # an empty session would no longer count as empty.
      def clear_report_claims(parent_id, state_dir:)
        return unless File.exist?(path(parent_id, state_dir: state_dir))

        locked(parent_id, state_dir: state_dir) do
          all = read(parent_id, state_dir: state_dir)
          changed = false
          all.each_value do |data|
            next unless data.is_a?(Hash)

            changed = true if data.delete("report_claim")
          end
          write(parent_id, all, state_dir: state_dir) if changed
        end
      end

      # Add the cursors of +entries+ (child id → cursor fields, as #read
      # gives them) that the parent has none for; one it has is kept.
      # @return [Array<String>] the child ids added
      def merge(parent_id, entries, state_dir:)
        return [] if entries.empty?

        locked(parent_id, state_dir: state_dir) do
          all = read(parent_id, state_dir: state_dir)
          added = entries.keys - all.keys
          write(parent_id, all.merge(entries.slice(*added)), state_dir: state_dir) unless added.empty?
          added
        end
      end

      def locked(parent_id, state_dir:)
        LOCK.synchronize do
          dir = Session.session_dir(parent_id, state_dir: state_dir)
          FileUtils.mkdir_p(dir)
          File.open(File.join(dir, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          end
        end
      end

      def get_from(all, child_id)
        DelegateCursor.from_json_hash(all[child_id])
      end

      def path(parent_id, state_dir:)
        File.join(Session.session_dir(parent_id, state_dir: state_dir), FILE)
      end

      # @return [Hash{String => Hash}] child id → cursor fields; {} when none
      #   or unreadable
      def read(parent_id, state_dir:)
        data = JSON.parse(File.read(path(parent_id, state_dir: state_dir)))
        data.is_a?(Hash) ? data : {}
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end

      def write(parent_id, all, state_dir:)
        file = path(parent_id, state_dir: state_dir)
        FileUtils.mkdir_p(File.dirname(file))
        AtomicFile.write(file, JSON.generate(all))
      end
    end
  end
end
