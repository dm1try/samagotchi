# frozen_string_literal: true

require_relative "../participant_prompts"
require_relative "../session"
require_relative "../log"

module Samagotchi
  module Web
    # A participant's own prompts for their composer's ↑/↓, mixed into App:
    # recorded when chi web accepts their turn (ParticipantAccess#
    # participant_turn_result), keyed by their grant's id, never by a body
    # field. The owner's machine-wide PromptHistory (GET /api/history, an
    # :owner route) is never read or written for a participant. Uses App's
    # @grants, #default_state_dir and @participant_prompts_mutex (set in
    # ParticipantAccess#init_participant_access). See
    # docs/internals/participants.md (A participant's prompt history).
    module ParticipantHistory
      private

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
