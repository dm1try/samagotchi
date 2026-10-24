# frozen_string_literal: true

require_relative "grants"
require_relative "qr"
require_relative "../review_start"
require_relative "../review_apply"
require_relative "../session_metrics"
require_relative "../participants"
require_relative "../session"

module Samagotchi
  module Web
    # The owner's routes for a session's participants, mixed into App:
    # invite, list, revoke, a participant's cap, and the review Apply (the
    # owner's turn quoting a review turn's proposal). What a participant
    # may do themselves is ParticipantAccess's. See
    # docs/internals/participants.md.
    module ParticipantsAdmin
      private

      # GET /api/sessions/:id/participants, GET /api/participants: the
      # grants (one session's, or every one), in every state, never a token
      # or digest. One session's also carries +warning+: the share warning
      # for a session that isn't a review session (ReviewStart.share_warning,
      # null for one), which the panel shows before its Invite.
      def handle_participants_list(_req, id = nil)
        now = @grants.now
        grants = @grants.list(session_id: id).map { |grant| grant.public_h(now) }
        return json_response(200, { participants: grants }) unless id

        warning = ReviewStart.share_warning(Session.load(id, state_dir: default_state_dir))
        json_response(200, { participants: with_spend(id, grants), warning: warning })
      end

      # One session's grants with what each spent and how many turns they
      # ran (its saved analytics: SessionMetrics.saved_by_author), for the
      # owner's participants panel.
      def with_spend(id, grants)
        rows = SessionMetrics.saved_by_author(Session.session_dir(id, state_dir: default_state_dir))
        grants.map do |grant|
          row = rows[Steer.author_for(grant[:id])] || { turns: 0, cost: 0.0 }
          grant.merge(spend: row[:cost].round(4), turns: row[:turns])
        end
      end

      # POST /api/sessions/:id/participants {name, kind?, ttl? (seconds),
      # cap? (dollars)}: a new grant. The answer carries the token and the
      # link once (chi keeps only its digest), and +warning+ for a session
      # that isn't a review session (ReviewStart.share_warning; null for one).
      def handle_participants_invite(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        ttl = body["ttl"]
        return error_response(400, "invalid_participant", "ttl is a number of seconds") unless ttl.nil? || ttl.is_a?(Integer)

        cap = body["cap"]
        return error_response(400, "invalid_participant", Grants::CAP_RANGE) unless cap.nil? || Grants.cap?(cap)

        issued = Participants.invite(@grants, session_id: id, name: body["name"], kind: (body["kind"] || "human").to_s,
                                              ttl: ttl, cap: cap, state_dir: default_state_dir)
        link = participant_link(req, id, issued.token)
        warning = ReviewStart.share_warning(Session.load(id, state_dir: default_state_dir))
        json_response(201, { participant: issued.grant.public_h(@grants.now), token: issued.token,
                             link: link, lan: !@lan.nil?, qr_svg: QR.svg(link), warning: warning })
      rescue Grants::Invalid => e
        error_response(400, "invalid_participant", e.message)
      end

      # GET /api/sessions/:id/apply[?turn=T] (owner): the owner's turn that
      # applies review turn T's proposal (ReviewApply: the reply quoted
      # under one line of the owner's), for the composer: never sent from
      # here. Without turn, the latest review turn with a reply. Read from
      # the live worker's messages, else the saved ones.
      # @return 200 {text, turn_id, author, author_name}; 404 not_found (no
      #   such turn, or no review turn); 400 not_review_turn; 409 no_reply
      def handle_apply(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        live = bridge_get_json(id, "snapshot")
        messages = live_or_saved(live && live["snapshot"], "messages") { session.messages }
        proposal = ReviewApply.find(messages, req.params["turn"])
        json_response(200, { text: ReviewApply.compose(proposal), turn_id: proposal.turn_id, author: proposal.author,
                             author_name: proposal.author_name })
      rescue ReviewApply::Refused => e
        status = { not_found: 404, not_review_turn: 400, no_reply: 409 }.fetch(e.code)
        error_response(status, e.code.to_s, e.message)
      end

      # DELETE /api/sessions/:id/participants[?id=p_…], DELETE
      # /api/participants: revokes one participant, a session's or every
      # one's; their open streams end within a poll.
      def handle_participants_revoke(req, id = nil)
        grant_id = req.params["id"]
        if grant_id && !Grants::ID_RE.match?(grant_id.to_s)
          return error_response(400, "invalid_participant", "not a participant id: #{grant_id.to_s[0, 40]}")
        end

        revoked = Participants.revoke(@grants, session_id: id, id: grant_id, by: "owner", state_dir: default_state_dir)
        now = @grants.now
        json_response(200, { revoked: revoked.map { |grant| grant.public_h(now) } })
      end

      # POST /api/sessions/:id/participants/:participant/cap {cap}: the
      # active participant's new spending cap (dollars), from their next
      # turn on. 200 {participant}; 400 invalid_participant.
      def handle_participants_cap(req, id, grant_id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        unless Grants::ID_RE.match?(grant_id.to_s)
          return error_response(400, "invalid_participant", "not a participant id: #{grant_id.to_s[0, 40]}")
        end

        grant = Participants.set_cap(@grants, session_id: id, id: grant_id, cap: body["cap"], state_dir: default_state_dir)
        return error_response(400, "invalid_participant", Participants.no_participant(grant_id, id)) unless grant

        json_response(200, { participant: grant.public_h(@grants.now) })
      rescue Grants::Invalid => e
        error_response(400, "invalid_participant", e.message)
      end

      # The link a participant opens: this chi web's LAN address when it has
      # one (the owner may be asking on loopback), else the Host asked; the
      # token traded for the cookie, the session in the fragment.
      def participant_link(req, id, token)
        host = req.get_header("HTTP_HOST").to_s
        port = host[/:(\d+)\z/, 1] || req.port.to_s
        name = @lan ? @lan[:ip] : host.sub(/:\d*\z/, "")
        "http://#{name}:#{port}/?token=#{token}#s=#{id}"
      end
    end
  end
end
