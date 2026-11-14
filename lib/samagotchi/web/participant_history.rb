# frozen_string_literal: true

require_relative "../participant_messages"
require_relative "../participant_prompts"
require_relative "../redact"
require_relative "../session"
require_relative "../log"

module Samagotchi
  module Web
    # A participant's own prompts for their composer's ↑/↓, mixed into App:
    # recorded when chi web accepts their turn (ParticipantAccess#
    # participant_turn_result), keyed by their grant's id, never by a body
    # field. The owner's machine-wide PromptHistory (GET /api/history, an
    # :owner route) is never read or written for a participant, and this
    # route serves only the caller's own list, redacted. Uses App's @grants,
    # @hub, @session_class, #default_state_dir, #principal, #owner_secrets
    # (ParticipantReview) and @participant_prompts_mutex (set in
    # ParticipantAccess#init_participant_access). See
    # docs/internals/participants.md (A participant's prompt history).
    module ParticipantHistory
      # GET /api/sessions/:id/prompt_history (:participant, :session: the
      # router answers another session's id as unknown first): the
      # caller's own prompts, oldest first, each as their conversation shows
      # it (Redact.text with their viewer: secret shapes, the owner's token
      # and cookie, the session folder relative, home as ~), as {entries}.
      # Keyed by the principal's grant only; no query or body is read. The
      # owner's list is GET /api/history: here a plain 403 (no audit line,
      # there's no grant to audit against).
      def handle_prompt_history(req, _id)
        principal = principal(req)
        return error_response(403, "not_permitted", ParticipantMessages::NOT_PERMITTED) if principal.owner?

        grant = principal.grant
        dir = Session.session_dir(grant.session_id, state_dir: default_state_dir)
        viewer = Redact::Viewer.new(author: grant.author, cwd: prompt_history_cwd(grant.session_id), secrets: owner_secrets)
        json_response(200, { entries: ParticipantPrompts.entries(dir, grant.id).map { |entry| Redact.text(entry, viewer) } })
      end

      private

      # The session's folder for the redaction: the hub's cached session (no
      # session load), else (no hub, or one that hasn't seen it) the saved
      # session's, as the show's viewer reads it (ParticipantReview#
      # participant_viewer). A missing session raises ArgumentError: the
      # :session route's unknown session.
      def prompt_history_cwd(id)
        @hub&.working_directory(id) || @session_class.load(id, state_dir: default_state_dir).working_directory
      end

      # Records +prompt+ as +grant+'s newest (ParticipantPrompts#append),
      # with the session's grants the store still knows as the live ones
      # (the others' lists are pruned). An over-long prompt is skipped before
      # the lock. A failed write never fails the send.
      def record_participant_prompt(grant, prompt)
        return unless ParticipantPrompts.recordable(prompt)

        dir = Session.session_dir(grant.session_id, state_dir: default_state_dir)
        live = @grants.list(session_id: grant.session_id).map(&:id)
        @participant_prompts_mutex.synchronize do
          ParticipantPrompts.append(dir, grant_id: grant.id, text: prompt, live_grant_ids: live)
        end
      rescue StandardError => e
        Log.warn(:web, "participant_prompt_write_failed", error: e.class.name, msg: e.message)
      end
    end
  end
end
