# frozen_string_literal: true

require_relative "session"
require_relative "owner_lock"
require_relative "session_inbox"

module Samagotchi
  # The one rule for putting a context note into a session, shared by
  # `chi note`, the agent's send_note, `chi broadcast` and /objectives: a
  # note delivery (SessionInbox.deliver :note). A note to a link that was
  # continued goes to its chain's newest link (SessionInbox::Head); a
  # session a one-turn chi run owns, or a chi scratch session, refuses it;
  # any other gets the note in its notes/ folder, which a live worker adds
  # within seconds and a session with no worker at its next start (a note
  # never starts one). Callers word the outcome (#refusal for a refused one).
  module NoteDelivery
    # Why a one-turn chi run's session takes no note.
    ONE_SHOT_REFUSAL = "it is #{OwnerLock::TUI_BUSY}; send the note once it ends"

    # The outcome for one session.
    # @!attribute id [String] the session that has the note: +asked+, or
    #   the newest link of its chain
    # @!attribute status [Symbol] :queued (a worker runs it or is starting),
    #   :waits (no worker: it waits for the next start) or :refused (a
    #   one-turn chi run owns it, or it is a chi scratch session: +scratch+)
    # @!attribute queued [Integer] notes waiting in its notes/ folder
    #   (:waits only; 0 otherwise)
    # @!attribute asked [String] the id the caller named (+id+ by default)
    Result = Data.define(:id, :status, :queued, :scratch, :asked) do
      def initialize(id:, status:, queued:, scratch: false, asked: nil) = super(id:, status:, queued:, scratch:, asked: asked || id)

      def delivered? = status != :refused

      # The note went on to a later link of +asked+'s chain.
      def continued? = asked != id

      # Why a refused note was refused, in its condition's one wording.
      def refusal = scratch ? Session::SCRATCH_REFUSED : ONE_SHOT_REFUSAL
    end

    module_function

    # @param id [String] a full session id (resolved by the caller)
    # @param objectives [Hash, nil] an objectives note's payload
    # @param pin [Boolean] keep it in +id+, never its chain's newest link
    #   (an /objectives list is the conversation of +id+'s own)
    # @param resolved [SessionInbox::Resolved, nil] the link the caller
    #   resolved already (SessionInbox::Head.resolve(:note, id)): no second walk
    # @return [Result]
    # @raise [SessionInbox::NoteRejected] an empty note or one over 16 KiB
    # @raise [Session::NotFound] no such session
    def deliver(id, text:, source:, state_dir:, from_session: nil, from_cwd: nil, objectives: nil, pin: false,
                resolved: nil)
      body = SessionInbox.checked_text(text)
      delivered = SessionInbox.deliver(:note, id, state_dir: state_dir, pin: pin, resolved: resolved) do |at|
        SessionInbox.write_note(at, text: body, source: source, from_session: from_session, from_cwd: from_cwd,
                                    objectives: objectives, state_dir: state_dir)
        false
      end
      raise Session::NotFound, id if delivered.wake == :gone

      Result.new(id: delivered.id, asked: delivered.asked, status: delivered.status, queued: delivered.queued || 0,
                 scratch: delivered.refused? && delivered.wake == :scratch)
    end
  end
end
