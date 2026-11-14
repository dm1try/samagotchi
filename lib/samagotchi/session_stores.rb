# frozen_string_literal: true

module Samagotchi
  # The files that hold state for a session, including stores outside its
  # sidecar directory. `corpus_dir` is relative to the compatibility corpus.
  # A Symbol in `continue` names the carry step; a String explains why it stays.
  module SessionStores
    Store = Data.define(:file, :owner, :removal, :cross_version, :continue, :corpus_dir, :corpus_exception) do
      def initialize(file:, owner:, removal:, cross_version:, continue:, corpus_dir:, corpus_exception: nil)
        super
      end

      def carried? = continue.is_a?(Symbol)

      def corpus_exception? = !corpus_exception.nil?
    end

    SIDE_CAR = "sessions/compat-session"
    CONTEXT = "context/sessions/compat-session"

    STORES = [
      Store.new(file: "archived", owner: "ArchiveStore", removal: :session_files, cross_version: true,
                continue: "the archived link remains its own session", corpus_dir: SIDE_CAR),
      Store.new(file: "state.json", owner: "PluginSessionState", removal: :plugin_session_state, cross_version: false,
                continue: "bundle state stays with the archived link", corpus_dir: nil),
      Store.new(file: "left.json", owner: "ContextSources", removal: :context_sources, cross_version: true,
                continue: :context, corpus_dir: CONTEXT),
      Store.new(file: "participants.json", owner: "Participants", removal: :participants, cross_version: true,
                continue: "a continue ends the previous link's participants", corpus_dir: SIDE_CAR),
      Store.new(file: "participant_images.json", owner: "ParticipantUploads", removal: :session_files, cross_version: true,
                continue: "a continue ends the previous link's participants", corpus_dir: SIDE_CAR),
      Store.new(file: "participant_prompts.json", owner: "ParticipantPrompts", removal: :session_files, cross_version: true,
                continue: "a continue ends the previous link's participants", corpus_dir: SIDE_CAR),
      Store.new(file: "judgments.jsonl", owner: "SystemOne::RunsStore", removal: :system_one_runs, cross_version: false,
                continue: "saved judgments belong to the previous link", corpus_dir: nil),
      Store.new(file: "context_candidates.jsonl", owner: "ContextCandidatesLog", removal: :context_candidates_log,
                cross_version: false, continue: "candidate records belong to the previous link", corpus_dir: nil),
      Store.new(file: "bridge.json", owner: "WorkerSidecar", removal: :session_files, cross_version: true,
                continue: "the bridge endpoint belongs to the old worker", corpus_dir: SIDE_CAR),
      Store.new(file: "cards.json", owner: "Bridge::CardStore", removal: :session_files, cross_version: true,
                continue: "cards describe turns in the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "pending_card.json", owner: "Bridge::PendingCard", removal: :session_files, cross_version: true,
                continue: "an open card belongs to its running turn", corpus_dir: SIDE_CAR),
      Store.new(file: "turn_drawings.jsonl", owner: "Bridge::TurnDrawings", removal: :session_files, cross_version: true,
                continue: "drawings describe turns in the previous link", corpus_dir: "sessions/compat-drawn"),
      Store.new(file: "move.json", owner: "ChildMove", removal: :session_files, cross_version: true,
                continue: "an interrupted move belongs to the previous continue", corpus_dir: SIDE_CAR),
      Store.new(file: "continued_from.json", owner: "ContinuedFrom", removal: :session_files, cross_version: true,
                continue: "the record names the continue that made this link", corpus_dir: SIDE_CAR),
      Store.new(file: "continue.json", owner: "ContinueIntent", removal: :session_files, cross_version: true,
                continue: "the intent records the previous link's continue", corpus_dir: SIDE_CAR),
      Store.new(file: "objectives.lock", owner: "Objectives", removal: :session_files, cross_version: false,
                continue: "a lock is not session data", corpus_dir: SIDE_CAR),
      Store.new(file: "objectives_cards.json", owner: "Objectives", removal: :session_files, cross_version: true,
                continue: "proposal answers belong to the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "objective_checks.jsonl", owner: "ObjectivesCheck", removal: :session_files, cross_version: true,
                continue: "checks belong to the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "objective_tracks.jsonl", owner: "ObjectivesTrack", removal: :session_files, cross_version: true,
                continue: "tracks belong to the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "owner.lock", owner: "OwnerLock", removal: :session_files, cross_version: false,
                continue: "the owner lock is not session data", corpus_dir: SIDE_CAR),
      Store.new(file: "reminders.json", owner: "ReminderCarry", removal: :session_files, cross_version: true,
                continue: "a restart hand-off is not a continue carry", corpus_dir: SIDE_CAR),
      Store.new(file: "recap.json", owner: "RecapStore", removal: :session_files, cross_version: true,
                continue: "the recap remains with the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "stopped", owner: "Session", removal: :session_files, cross_version: true,
                continue: "the stop marker belongs to the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "parent.json", owner: "Session", removal: :session_files, cross_version: true,
                continue: :children, corpus_dir: SIDE_CAR),
      Store.new(file: "starting", owner: "StartingMarker", removal: :session_files, cross_version: true,
                continue: "a start marker belongs to its spawn", corpus_dir: nil,
                corpus_exception: "the corpus marker would always be stale, so it cannot pin the live-start handshake"),
      Store.new(file: "thinking_tails.jsonl", owner: "ThinkingTails", removal: :session_files, cross_version: true,
                continue: "generation tails remain with the previous link", corpus_dir: SIDE_CAR),
      Store.new(file: "delegates.json", owner: "Tools::DelegateCursors", removal: :session_files, cross_version: true,
                continue: :children, corpus_dir: SIDE_CAR),
      Store.new(file: "delegates.lock", owner: "Tools::DelegateCursors", removal: :session_files, cross_version: false,
                continue: "a lock is not session data", corpus_dir: SIDE_CAR)
    ].freeze

    def self.removal_stores = STORES.map(&:removal).uniq.freeze

    def self.corpus_stores = STORES.select(&:cross_version).freeze
  end
end
