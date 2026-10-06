# frozen_string_literal: true

require_relative "session"
require_relative "session_inbox"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # The one rule for putting a context note into a session, shared by
  # `chi note`, the agent's send_note and `chi broadcast`: a session a chi
  # REPL owns refuses it (notes need attached mode); any other gets the
  # note in its notes/ folder, which a live worker adds within seconds and
  # a session with no worker at its next start. Callers word the outcome.
  module NoteDelivery
    # The outcome for one session.
    # @!attribute status [Symbol] :queued (a worker runs it), :waits (no
    #   worker: it waits for the next start) or :refused (a chi REPL owns it)
    # @!attribute queued [Integer] notes waiting in its notes/ folder
    #   (:waits only; 0 otherwise)
    Result = Data.define(:id, :status, :queued) do
      def delivered? = status != :refused
    end

    module_function

    # @param id [String] a full session id (resolved by the caller)
    # @return [Result]
    # @raise [SessionInbox::NoteRejected] an empty note or one over 16 KiB
    def deliver(id, text:, source:, state_dir:, from_session: nil, from_cwd: nil)
      owner = SessionManager.session_owner(id, state_dir: state_dir)
      return Result.new(id: id, status: :refused, queued: 0) if owner&.tui?

      path = SessionInbox.write_note(id, text: text, source: source, from_session: from_session, from_cwd: from_cwd,
                                         state_dir: state_dir)
      return Result.new(id: id, status: :queued, queued: 0) if owner

      Result.new(id: id, status: :waits, queued: SessionInbox.find_new_note_files(File.dirname(path, 2)).size)
    end
  end
end
