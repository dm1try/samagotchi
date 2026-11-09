# frozen_string_literal: true

require_relative "session"
require_relative "owner_lock"
require_relative "session_inbox"

module Samagotchi
  # Loaded on first use (a note): keeps the bundle test kit's load budget
  # (spec/samagotchi/testing/sandbox_spec.rb).
  autoload :WorkerPresence, File.expand_path("worker_presence", __dir__)

  # Loaded on first use: this autoload keeps SessionManager and its ~80
  # files unloaded until the delegate/session path needs them.
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # The one rule for putting a context note into a session, shared by
  # `chi note`, the agent's send_note and `chi broadcast`: a session a
  # one-turn chi run owns, or a chi scratch session, refuses it; any other
  # gets the note in its notes/ folder, which a live worker adds within
  # seconds and a session with no worker at its next start. Callers word
  # the outcome (#refusal for a refused one).
  module NoteDelivery
    # Why a one-turn chi run's session takes no note.
    ONE_SHOT_REFUSAL = "it is #{OwnerLock::TUI_BUSY}; send the note once it ends"

    # The outcome for one session.
    # @!attribute status [Symbol] :queued (a worker runs it), :waits (no
    #   worker: it waits for the next start) or :refused (a one-turn chi run
    #   owns it, or it is a chi scratch session: +scratch+)
    # @!attribute queued [Integer] notes waiting in its notes/ folder
    #   (:waits only; 0 otherwise)
    Result = Data.define(:id, :status, :queued, :scratch) do
      def initialize(id:, status:, queued:, scratch: false) = super

      def delivered? = status != :refused

      # Why a refused note was refused, in its condition's one wording.
      def refusal = scratch ? Session::SCRATCH_REFUSED : ONE_SHOT_REFUSAL
    end

    module_function

    # @param id [String] a full session id (resolved by the caller)
    # @param objectives [Hash, nil] an objectives note's payload
    # @return [Result]
    # @raise [SessionInbox::NoteRejected] an empty note or one over 16 KiB
    def deliver(id, text:, source:, state_dir:, from_session: nil, from_cwd: nil, objectives: nil)
      presence = WorkerPresence.read(id, state_dir: state_dir, owner: SessionManager.session_owner(id, state_dir: state_dir))
      return Result.new(id: id, status: :refused, queued: 0) if presence.tui_owned?
      # Its terminal's alone, live or left behind.
      return Result.new(id: id, status: :refused, queued: 0, scratch: true) if Session.load(id, state_dir: state_dir).scratch

      path = SessionInbox.write_note(id, text: text, source: source, from_session: from_session, from_cwd: from_cwd,
                                         objectives: objectives, state_dir: state_dir)
      return Result.new(id: id, status: :queued, queued: 0) if presence.owned?

      Result.new(id: id, status: :waits, queued: SessionInbox.find_new_note_files(File.dirname(path, 2)).size)
    end
  end
end
