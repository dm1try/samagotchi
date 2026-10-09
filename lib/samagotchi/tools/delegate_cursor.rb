# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../atomic_file"
require_relative "../session"

module Samagotchi
  module Tools
    # What a parent was already told about one delegate child: the newest
    # reply it was given (+reply_file+, ReplyWait's cursor) and the child as
    # it was then (+messages+, +question_id+, +last_turn+: ReplyWait's
    # baseline). nil +messages+ means no baseline.
    DelegateCursor = Data.define(:reply_file, :last_turn, :question_id, :messages) do
      def self.empty = new(reply_file: nil, last_turn: nil, question_id: nil, messages: nil)

      # @param baseline [Hash, nil] ReplyWait.baseline_of's
      def with_baseline(baseline)
        b = baseline || {}
        with(messages: b[:messages], question_id: b[:question_id], last_turn: b[:last_turn])
      end

      # @return [Hash, nil] ReplyWait's baseline:, nil when none was taken
      def baseline
        return nil if messages.nil?

        { messages: messages, question_id: question_id, last_turn: last_turn }
      end

      def to_json_hash = to_h.transform_keys(&:to_s).compact
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
        data = all[child_id]
        return DelegateCursor.empty unless data.is_a?(Hash)

        DelegateCursor.new(reply_file: data["reply_file"], last_turn: data["last_turn"],
                           question_id: data["question_id"], messages: data["messages"])
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
