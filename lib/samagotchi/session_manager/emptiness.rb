# frozen_string_literal: true

require_relative "../analytics_file"
require_relative "../session_inbox"
require_relative "../worker_link"
require_relative "../starting_marker"

module Samagotchi
  class SessionManager
    # What a session's directory holds before anything happened in it. Any
    # other entry (or a file in one of the EMPTY_DIRS) is something the
    # session keeps. "pid" is the pid file workers wrote until 2026-10-01:
    # nothing writes or reads it now, but a folder from before still has one
    # and is still empty. A turn's drawing (Bridge::TurnDrawings::FILE)
    # exists only after a turn that kept messages: never a skeleton file.
    # The starting marker is one too: a start left one behind; a fresh one
    # keeps the session from the deleters itself.
    EMPTY_SKELETON_FILES = ["pid", "owner.lock", WorkerLink::FILE, AnalyticsFile::NAME, StartingMarker::FILE].freeze
    EMPTY_DIRS = [SessionInbox::INPUT_DIR, SessionInbox::NOTES_DIR, "images"].freeze
    EMPTY_SKELETON_DIRS = (EMPTY_DIRS + [SessionInbox::OUTPUT_DIR]).freeze

    # Emptiness: whether nothing happened in a session (pure predicates over
    # its file and directory) and whether one being left is deleted, asked by
    # WorkerCommandPart and the retention sweep. Calls no other part. Meant
    # to be loaded through samagotchi/session_manager.
    module EmptinessPart
      # session.keep_empty off: sessions left with nothing in them are deleted
      # (the worker as it exits, the retention sweep).
      def discard_empty?
        Degrade.call(:config, "keep_empty_unreadable", fallback: false) { Samagotchi::Config.get("session.keep_empty") != true }
      end

      # Whether a session being left (or found left) is deleted: session.keep_empty
      # is off and nothing happened in it (#empty_session?). The worker as it
      # leaves and the retention sweep both ask this.
      # @param default_model [String, nil] what a new session starts on
      # @param used_memory_names [Array<String>] memory its owner's Engine used
      #   before any save
      def discardable?(session_id, default_model:, state_dir: nil, used_memory_names: [])
        return false unless discard_empty? && Array(used_memory_names).empty?

        empty_session?(session_id, state_dir: state_dir || Session.default_state_dir, default_model: default_model)
      end

      # A session nothing happened in: no conversation, no turn tried (a failed
      # one leaves no messages but a last_prompt and analytics turns), nothing
      # queued or attached, and the model and mode a new session gets. A
      # session prepared for later (/model, --model, a note, an image, memory)
      # is not empty. Anything unreadable or unknown counts as not empty.
      # @param default_model [String, nil] what a new session starts on
      def empty_session?(session_id, state_dir: nil, default_model: nil)
        sd = state_dir || Session.default_state_dir
        session = Session.load(session_id, state_dir: sd)
        return false unless no_conversation?(session.messages) && session.pending_question.nil? && session.used_memory_names.empty?
        return false unless session.last_prompt.to_s.strip.empty? && session.first_preview.to_s.strip.empty?
        return false unless session.mode.to_s == "assist" && !default_model.nil? && same_model?(session.model_name, default_model)

        empty_session_dir?(Session.session_dir(session_id, state_dir: sd))
      rescue ArgumentError, SystemCallError, JSON::ParserError
        false
      end

      # Whether two model names resolve to the same ref (ModelRef#ref): a
      # session stores the resolved ref, the default may be an alias.
      def same_model?(one, other)
        return true if one.to_s == other.to_s
        return false if one.nil? || other.nil?

        Degrade.call(:config, "model_ref_unresolved", fallback: false) do
          HostConfig.model_ref(one).ref == HostConfig.model_ref(other).ref
        end
      end

      # Only the system prompt (an Engine seeds one, a saved session keeps
      # it); a context note is a system message too, but with its kind.
      # A turn note (the tail system message after a failed, cancelled or empty
      # turn) is not a conversation either: a session whose only turn failed
      # before any answer is still empty.
      def no_conversation?(messages)
        Array(messages).all? do |msg|
          (msg[:role] || msg["role"]).to_s == "system" &&
            ((msg[:kind] || msg["kind"]).nil? || TurnNote.note?(msg))
        end
      end

      # @return [Boolean] whether a session's directory holds only the skeleton
      def empty_session_dir?(dir)
        return true unless Dir.exist?(dir)

        Dir.children(dir).all? do |name|
          path = File.join(dir, name)
          if EMPTY_SKELETON_DIRS.include?(name)
            File.directory?(path) && (!EMPTY_DIRS.include?(name) || Dir.empty?(path))
          elsif name == AnalyticsFile::NAME
            analytics_empty?(path)
          # Cards and notices from before any turn (Bridge::CardStore).
          elsif name == "cards.json"
            cards_empty?(path)
          else
            # A starting claim's temp files a kill left (StartingMarker.claim:
            # starting.<pid>.<hex>, starting.old.<pid>.<hex>) are the marker's.
            EMPTY_SKELETON_FILES.include?(name) || name.start_with?("#{StartingMarker::FILE}.")
          end
        end
      end

      # A folder's analytics.json is empty only when it is a JSON object with
      # an empty turn_records array. Anything unreadable, not JSON, not an
      # object, the wrong type, or turn_records the wrong shape reads as
      # "not empty": a broken analytics keeps the folder instead of crashing
      # the retention sweep (or of a wrong-shape one reading as empty).
      def analytics_empty?(path)
        data = read_json(path)
        turns = data.is_a?(Hash) ? data["turn_records"] : nil
        turns.is_a?(Array) && turns.empty?
      end

      # A folder's cards.json is empty only when it is a JSON object with no
      # turn in it: an empty turn_log, or an older file's (Bridge::CardStore
      # version 1) turns an integer zero. Anything unreadable, not JSON, not an
      # object, the wrong type, or neither of those reads as "not empty": a
      # broken or wrong-shape cards file keeps the folder instead of raising
      # (Array#/Hash#to_i) or reading as empty.
      def cards_empty?(path)
        data = read_json(path)
        return false unless data.is_a?(Hash)

        turns = data["turns"]
        data["turn_log"] == [] || (turns.is_a?(Integer) && turns.zero?)
      end

      # A session-dir JSON file's contents, or nil when it is missing,
      # unreadable, not JSON or not an object (mirrors AnalyticsFile#read): a
      # broken file reads as none, so its folder is kept, not deleted.
      def read_json(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end

    extend EmptinessPart
  end
end
