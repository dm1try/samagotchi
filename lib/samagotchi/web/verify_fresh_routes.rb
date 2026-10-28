# frozen_string_literal: true

require_relative "../delivery"
require_relative "../participant_mode"
require_relative "../participant_messages"
require_relative "../participants"
require_relative "../session"
require_relative "../steer"
require_relative "../verify_fresh"

module Samagotchi
  module Web
    # POST /api/sessions/:id/verdicts/:check_turn_id/fresh, mixed into App:
    # Verify fresh (VerifyFresh) for the owner and for a participant. A
    # participant's is refused as their turn would be (their cap, counted
    # with their fresh children's spend; a worker that predates
    # participants' turns) and audited like one (participants.log,
    # verify_fresh); their child runs under the boundary their grant has
    # here now (ParticipantMode.live_for), saved on the child. See
    # docs/internals/participants.md (Verify fresh).
    module VerifyFreshRoutes
      private

      # Whose child it is (D6, the security review's MED-2): a verdict a
      # participant's turn recorded is re-checked AS that participant
      # (their author, their grant's mode, their cap), whoever clicks: its
      # quote is their text, never run with the owner's power. Their link
      # must still be live (else 409 author_link_ended). An owner's verdict
      # is re-checked as whoever clicks: the owner's child for the owner, the
      # clicking participant's for a participant. A participant who clicks
      # passes their own turn's refusals first.
      # @return 202 {of, running: true} (+child_id+ for the owner only)
      def handle_verify_fresh(req, id, of)
        clicker = principal(req).owner? ? nil : principal(req).grant
        session = @session_class.load(id, state_dir: default_state_dir)
        if clicker && (refused = participant_cap_refusal(clicker) || fresh_worker_refusal(session, participant: true))
          return verify_fresh_refused(clicker, of, *refused)
        end

        by = Steer.sender_author(field_of(VerifyFresh.original(session.verdicts, of), :by))
        runner = by ? verdict_author_grant(id, by) : clicker
        return author_link_ended(clicker, id, of, by) if by && runner.nil?
        if runner && runner != clicker && (refused = participant_cap_refusal(runner) ||
                                                   fresh_worker_refusal(session, participant: true))
          return verify_fresh_refused(clicker, of, *refused, runner: runner)
        end
        if (refused = fresh_worker_refusal(session))
          return verify_fresh_refused(clicker, of, *refused, runner: runner)
        end

        mode = runner && ParticipantMode.live_for(session, runner, state_dir: default_state_dir)
        child = VerifyFresh.start(id, of: of, author: runner&.author, mode: mode, state_dir: default_state_dir,
                                      spawn: fresh_spawn)
        audit_verify_fresh(clicker, of, status: "accepted", child: child.id, mode: mode&.to_s, runner: runner)
        json_response(202, clicker ? { of: of, running: true } : { of: of, running: true, child_id: child.id })
      rescue VerifyFresh::Refused => e
        verify_fresh_refused(clicker, of, e.status, e.code, e.message, runner: runner)
      end

      # The live grant of the participant +author+ ("p:<id>") in session
      # +id+, nil when it is gone, revoked or expired.
      def verdict_author_grant(id, author)
        grant = @grants.find(Steer.participant_id(author))
        grant if grant && grant.session_id == id && grant.active?(@grants.now)
      end

      # 409 author_link_ended: the verdict's participant can't be charged or
      # bounded any more, so no child runs for it.
      def author_link_ended(clicker, id, of, author)
        pid = Steer.participant_id(author)
        name = Participants.read(id, state_dir: default_state_dir).find { |entry| entry.id == pid }&.name
        name = pid if name.to_s.strip.empty?
        detail = format(AUTHOR_LINK_ENDED, name: name)
        audit_verify_fresh(clicker, of, status: "refused", reason: "author_link_ended", participant_id: pid) if clicker
        error_response(409, "author_link_ended", detail)
      end

      AUTHOR_LINK_ENDED = "%<name>s's link has ended: their verdict can't be checked again as theirs " \
                          "(re-invite them, or verify the claim yourself)"

      def field_of(record, key) = record && (record[key] || record[key.to_s])

      # A live worker must support VerifyFresh's parent checks. For a
      # participant's child it must also have the review boundary.
      def fresh_worker_refusal(session, participant: false)
        features = ParticipantMode.live_features(session, default_state_dir)
        return nil if features.nil?
        return [409, VerifyAnchor::UNAVAILABLE["error"], VerifyAnchor::UNAVAILABLE["detail"]] if VerifyAnchor.worker_unavailable?(features)
        return nil unless participant && !features.include?(Delivery::REVIEW_FEATURE)

        [409, Delivery::REVIEW_UNAVAILABLE["error"], Delivery::REVIEW_UNAVAILABLE["detail"]]
      end

      def verify_fresh_refused(clicker, of, status, code, detail, runner: nil)
        audit_verify_fresh(clicker, of, status: "refused", reason: code, runner: runner)
        error_response(status, code, detail)
      end

      # Audited in the participants' trail when a participant clicked or the
      # child runs as one: +clicker+ the participant who asked (nil: the
      # owner), +runner+ whose child it is.
      def audit_verify_fresh(clicker, of, status:, runner: nil, participant_id: nil, **fields)
        subject = runner || clicker
        return if subject.nil? && participant_id.nil?

        Participants.log(subject&.session_id || clicker.session_id, :verify_fresh, state_dir: default_state_dir,
                                                                                   participant: subject&.id || participant_id,
                                                                                   asked_by: clicker ? clicker.id : "owner",
                                                                                   of: of.to_s[0, 64], status: status, **fields.compact)
      end

      def fresh_spawn = ->(**options) { @manager.spawn_session(**options) }
    end
  end
end
