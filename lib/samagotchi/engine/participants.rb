# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session's participants: the running turn's author, a pair turn's
    # stop check, who came or went, the system prompt's participants line and
    # a participant's author fields. Writes @participant_stop,
    # @participants_line; reads @participants, @participants_watch and the
    # turn's TurnContext.
    module ParticipantsPart
      # The running turn's author when a participant wrote it, else nil
      # (ctx.turn_author, the hooks' author, the judgments' participant:,
      # ObjectivesCheck): one read of the published TurnContext, so any
      # thread sees the running turn's author from its first moment, never
      # the last turn's.
      # @return [String, nil]
      def turn_author = turn_context&.author

      # Whether a participant's pair turn must stop, read before each of its
      # generations (#guard_participant_spend): author ("p:<id>") → why (their
      # link ended, or they passed their cap), nil while it may go on. The
      # Worker sets it (Worker#participant_turn_stop); without one (a one-shot)
      # nothing is checked mid-turn.
      attr_writer :participant_stop

      # Before each generation (KernelLoop#generation_guard): a pair turn whose
      # participant's link ended, or whose spend (Engine#metrics: their
      # finished turns, this one's finished generations, their side requests)
      # passed their cap, stops on the plugins' stop path (cost-cap's,
      # work-cap's), with its notice. A generation's own cost is known only
      # once it ends, so a turn can pass the cap by its last generation. The
      # turn-start check is the Worker's (Worker#participant_refusal); a
      # review turn only reads, and keeps to it.
      # @param context [TurnContext] the running turn's (the loop's)
      def guard_participant_spend(context)
        author = context&.author
        return if author.nil? || @participant_stop.nil?
        return unless context.participant_mode == ParticipantMode::PAIR

        reason = @participant_stop.call(author) or return
        hook_stop_turn(reason, PARTICIPANTS_HOOK)
      end
      private :guard_participant_spend

      # A participant joined (invited) or left (revoked, expired) since the
      # last look: :participants_changed to the observers (ParticipantsWatch;
      # the worker looks on its idle tick). The first look announces nobody.
      # @return [ParticipantsWatch::Change, nil]
      def announce_participants
        change = @participants_watch.changes or return nil

        announce(change.to_event)
        change
      end

      # Reads the session's participants at a turn's start; the first to join,
      # the first invited to act (a pair participant: the line's words) and
      # the last to leave rebuild the system prompt (its participants line),
      # once each: a turn in between sends the same prefix.
      def refresh_participants!(session)
        line = @participants.refresh!(session).prompt_mode(session)
        return if line == @participants_line

        @participants_line = line
        @prompt_builder.reset!
      end
      private :refresh_participants!

      # The author fields a message +author+ wrote carries (Steer.author_fields:
      # author:, and author_name: from participants.json), {} for the owner.
      # The worker's drain names a participant's merged lines with it, and
      # its running save a participant's prompt.
      # @param author [String, nil] a turn's or a line's author (TurnOrigin#author)
      # @param session [Session, nil] the session it is for (the turn's)
      def author_fields(author, session: @session)
        return {} unless Steer.participant_author?(author)

        Steer.author_fields(author, @participants.name_for(author, session: session))
      end

      # A participant's opening message keeps the rules it was delivered under
      # (ParticipantMode), stamped before any request carries it, so its header
      # never changes when the session's mode does.
      # @param context [TurnContext] the turn's
      def participant_mode_fields(context)
        mode = context.participant? && context.participant_mode
        mode ? { participant_mode: mode.to_s } : {}
      end
    end
  end
end
