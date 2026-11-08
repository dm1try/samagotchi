# frozen_string_literal: true

require "time"
require_relative "../answer_tail"
require_relative "../log"
require_relative "../output_formatter"
require_relative "../redact"
require_relative "../revise_anchor"
require_relative "../session"
require_relative "../steer"
require_relative "../verdict"
require_relative "../verify_anchor"

module Samagotchi
  module TurnStages
    # Verify and Revise anchors over a turn: a Verify turn's quote checked
    # against its source session as the turn begins; at its end (inside
    # Engine#end_turn's event step) the opening's stamp, a Revise turn's
    # draft checked and a Verify turn's verdict recorded. No state of its
    # own: it reads the turn, and the sessions it loads from the state dir
    # it is given.
    class VerifyAnchors
      # A Verify turn's claim (Engine#begin_turn), when its quote is in the
      # source session's answer for that turn; nil (logged) otherwise.
      # @param anchor [VerifyAnchor, nil]
      # @param state_dir [String] the sessions dir (a fresh Verify child's
      #   parent is loaded from it): the Engine's at the call, as no
      #   TurnContext holds it yet
      # @return [VerifyAnchor, nil]
      def verified(session, anchor, state_dir:)
        return unless anchor

        source = source_session(session, anchor, state_dir)
        return unless source

        turn = AnswerTail.turn_slice(Array(source.messages), anchor.turn_id)
        return reject_verify(anchor, :turn_missing) unless turn

        reply = turn.reverse.find { |message| AnswerTail.answer?(message) }
        return reject_verify(anchor, :reply_missing) unless reply

        quote_text = comparison_text(anchor.quote)
        quoted = !quote_text.empty? && quote_in?(quote_text, (reply[:content] || reply["content"]).to_s, source)
        return reject_verify(anchor, :quote_missing) unless quoted

        anchor
      end

      # The turn's anchors, stamped on its opening message (the prompt, or a
      # wake turn's note) in the messages it keeps: display metadata, never
      # in the prompt (LLM::ChatLoop#plain keeps them, no wire sends them).
      # A Verify turn's claim however it ended; a Revise turn's draft only
      # once it completed with an answer (#revision_target). Returns the
      # stamped ReviseAnchor (the end event's revises), or nil.
      def stamp_opening(messages, turn, outcome)
        return unless messages.is_a?(Array)

        revises = revision_target(messages, turn, outcome)
        fields = { verify: turn.verify&.to_h, revises: revises&.to_h }.compact
        return if fields.empty?

        opening = messages.reverse.find do |message|
          Steer.turn_prompt?(message) && (message[:turn_id] || message["turn_id"]).to_s == turn.id
        end
        return unless opening

        opening.merge!(fields)
        revises
      end

      # A completed Verify turn's verdict (Verdict.parse of its answer), added
      # to the session's verdicts; the record (the end event's verdict), or nil.
      def record_verdict(turn, outcome)
        return unless outcome == "completed" && turn.verify

        answer = AnswerTail.find(turn.session.messages, turn_id: turn.id)
        parsed = Verdict.parse(answer && (answer[:content] || answer["content"]))
        return unless parsed

        record = { anchor: turn.verify.to_h, verdict: parsed.verdict, reason: parsed.reason,
                   by: turn.origin.author, check_turn_id: turn.id, at: Time.now.iso8601(3) }
        turn.session.verdicts = turn.session.verdicts + [record]
        record
      end

      private

      # The turn a Revise turn revised (D6: "this turn revised that one"):
      # only a completed turn with an answer (AnswerTail) has revised
      # anything. A draft no prompt in the messages carries is no target (a
      # stale page, a rolled-back turn); one a stamped turn already revised
      # is re-targeted to its stack's top, the newest version, which the
      # person meant ("this draft").
      def revision_target(messages, turn, outcome)
        return unless turn.revises && outcome == "completed"

        slice = AnswerTail.turn_slice(messages, turn.id)
        return unless slice&.any? { |message| AnswerTail.answer?(message) }

        target = turn.revises.turn_id
        seen = [turn.id]
        until seen.include?(target)
          return reject_revise(turn.revises, :turn_missing) unless AnswerTail.turn_slice(messages, target)

          seen << target
          newer = messages.reverse.find do |message|
            Steer.turn_prompt?(message) && ReviseAnchor.from(message[:revises] || message["revises"])&.turn_id == target
          end
          return ReviseAnchor.new(turn_id: target) unless newer

          target = (newer[:turn_id] || newer["turn_id"]).to_s
        end
        reject_revise(turn.revises, :cycle)
      end

      def reject_revise(anchor, reason)
        Log.warn(:turn, "revise_anchor_rejected", turn_id: anchor.turn_id, reason:)
        nil
      end

      # Whether +quote_text+ is in +answer+ as the model wrote it, or as the
      # pages show it: a page quotes its own text, which reads the session's
      # folder relative, the home folder as ~ and a secret shape as
      # [redacted] (a participant's page gets it so, Redact;
      # the owner's page rewrites its quote the same way, claim_link.js
      # normalizeClaim, so claim links match both pages). +source+ is the
      # session whose folder that is.
      def quote_in?(quote_text, answer, source)
        return true if comparison_text(answer).include?(quote_text)

        viewer = Redact::Viewer.new(cwd: source.working_directory)
        comparison_text(Redact.text(answer, viewer)).include?(quote_text)
      end

      def source_session(session, anchor, state_dir)
        return session unless session.verify_fresh

        fresh = session.verify_fresh
        return reject_verify(anchor, :fresh_anchor_mismatch) unless fresh.anchor == anchor
        return reject_verify(anchor, :fresh_parent_missing) unless session.parent_id

        Session.load(session.parent_id, state_dir: state_dir)
      rescue ArgumentError, SystemCallError, IOError => e
        Log.warn(:turn, "verify_anchor_rejected", turn_id: anchor.turn_id, reason: :source_session_unavailable,
                                                   error: e.class.name)
        nil
      end

      def comparison_text(text)
        OutputFormatter.strip_markup(text)
                       .gsub(/!\[([^\]]*)\]\([^)]+\)/, '\1')
                       .gsub(/\[([^\]]+)\]\([^)]+\)/, '\1')
                       .gsub(/^[ \t]*(?:\#{1,6}[ \t]+|>[ \t]?|[-+*][ \t]+|\d+[.)][ \t]+)/, "")
                       .gsub(/(\*\*|__|~~|`+)(.+?)\1/m, '\2')
                       .gsub(/(?<!\w)\*(\S(?:.*?\S)?)\*(?!\w)/m, '\1')
                       .gsub(/(?<!\w)_(\S(?:.*?\S)?)_(?!\w)/m, '\1')
                       .tr("|", " ") # a table row's cells; the page copies them without the pipes
                       .gsub(/\s+/, " ")
                       .strip
      end

      def reject_verify(anchor, reason)
        Log.warn(:turn, "verify_anchor_rejected", turn_id: anchor.turn_id, reason:)
        nil
      end
    end
  end
end
