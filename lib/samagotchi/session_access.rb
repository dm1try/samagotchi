# frozen_string_literal: true

module Samagotchi
  # The seam between chi's session commands (chi send, answer, note,
  # session-scope context, sessions list/stop/restart/archive/unarchive/
  # delete) and where the sessions live. One object per command run:
  # Local reads and writes this machine's session files and workers; a
  # Remote (to come) does the same over another machine's chi web.
  # The commands keep their wording, exit codes and checks; what they ask
  # of a session goes through here. Session commands and flags that run on
  # this machine only are listed in SessionAccess::Contract. See
  # docs/architecture.md (Session access).
  module SessionAccess
    autoload :Local, File.expand_path("session_access/local", __dir__)

    # A session to create (chi send --new): a new one, or with +continues+
    # the next link of that session's chain (which brings its own folder,
    # LLM context, thinking, toolkit and settings: the rest is nil then).
    # +preview+ set: the session starts idle with it as its preview, and
    # +prompt+ (nil) goes in later as a turn (images, a session command).
    NewSession = Data.define(:prompt, :preview, :continues, :working_directory, :model_name, :setup) do
      def initialize(prompt:, preview: nil, continues: nil, working_directory: nil, model_name: nil, setup: nil) = super
    end

    # What chi send --wait and chi answer read before anything is sent, so
    # neither an older reply nor a turn that ends before the first look is
    # taken for the answer (ReplyWait's cursor:, baseline:, turn:).
    # @!attribute cursor [String, nil] the newest reply file already there
    # @!attribute baseline [ReplyWait::Baseline] the session as it was
    # @!attribute own_turn [String, nil] ReplyWait.own_turn: the turn
    #   running now, or the one whose continue offer stands
    # @!attribute known_turn [Boolean, nil] with a turn asked for
    #   (--turn), ReplyWait.known_turn?; nil without one
    # @!attribute running [Boolean] the session's status was running
    # @!attribute live [Boolean] running, or a worker or a REPL owns it
    # @!attribute settled [Boolean] idle, a turn ended and no question
    #   stands (a continue offer waits for its answer)
    # @!attribute last_turn_id [String, nil] the last ended turn's
    #   enqueued_id
    WaitStart = Data.define(:cursor, :baseline, :own_turn, :known_turn, :running, :live, :settled, :last_turn_id)

    # One attached context source as a session (or a project) sees it:
    # its Source and Snapshot (ContextSources), and for a session's list
    # whether it mutes it, a session source shadows it, and its text is
    # unread (nil for a project's, or where not asked).
    ContextEntry = Data.define(:source, :snapshot, :muted, :shadowed, :unread) do
      def initialize(source:, snapshot:, muted: nil, shadowed: nil, unread: nil) = super
    end

    # chi context push's outcome: :pushed (+before+ the revision it had,
    # +revision+ the new one), :missing (no such source) or :not_push (a
    # command source, whose text is its command's).
    ContextPush = Data.define(:status, :before, :revision) do
      def initialize(status:, before: nil, revision: nil) = super
    end
  end
end
