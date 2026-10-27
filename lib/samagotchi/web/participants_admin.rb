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
      # null for one), which the panel shows before its Invite; and
      # +identity_header+: the header this chi web's auth proxy names the
      # signed-in user in (null without one), for the Invite's email field;
      # +mode+: what a participant invited now gets, "pair" or "review"
      # (ReviewStart.share_terms), for the panel's words; +link_base+: where
      # a participant's link opens (participant_base), for a claim link
      # (claim_link.js) the participant's browser opens with its cookie.
      def handle_participants_list(req, id = nil)
        now = @grants.now
        grants = @grants.list(session_id: id).map { |grant| grant.public_h(now) }
        return json_response(200, { participants: grants }) unless id

        terms = ReviewStart.share_terms(Session.load(id, state_dir: default_state_dir), state_dir: default_state_dir)
        json_response(200, { participants: with_spend(id, grants), warning: terms.warning, mode: terms.mode.to_s,
                             identity_header: @public_url&.identity_header, link_base: participant_base(req) })
      rescue Grants::Unwritable => e
        grants_unwritable(e)
      end

      # 409 grants_unwritable for a store chi won't read or write over
      # (Grants::Corrupt, Grants::Newer), in the store's own words: a
      # refusal the panel shows, not a 500 with a backtrace per refresh.
      def grants_unwritable(error) = error_response(409, "grants_unwritable", error.message)

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
      # cap? (dollars), identity? (an email: the grant is bound to it, only
      # behind an auth proxy with an identity header)}: a new grant. The
      # answer carries the token and the link once (chi keeps only its
      # digest), and +warning+ for a session that isn't a review session
      # (ReviewStart.share_warning; null for one).
      def handle_participants_invite(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        ttl = body["ttl"]
        return error_response(400, "invalid_participant", "ttl is a number of seconds") unless ttl.nil? || ttl.is_a?(Integer)

        cap = body["cap"]
        return error_response(400, "invalid_participant", Grants::CAP_RANGE) unless cap.nil? || Grants.cap?(cap)

        # The grant is stamped pair only when the warning that comes back says
        # their turns act (one read: ReviewStart.share_terms).
        terms = ReviewStart.share_terms(Session.load(id, state_dir: default_state_dir), state_dir: default_state_dir)
        issued = Participants.invite(@grants, session_id: id, name: body["name"], kind: (body["kind"] || "human").to_s,
                                              ttl: ttl, cap: cap, identity: body["identity"], public_url: @public_url,
                                              mode: terms.grant_mode, state_dir: default_state_dir)
        link = participant_link(req, id, issued.token, expires_at: issued.grant.expires_at)
        json_response(201, { participant: issued.grant.public_h(@grants.now), token: issued.token,
                             link: link, lan: !@lan.nil? || !@public_url.nil?, qr_svg: QR.svg(link), warning: terms.warning })
      rescue Grants::Invalid => e
        error_response(400, "invalid_participant", e.message)
      rescue Grants::Unwritable => e
        grants_unwritable(e)
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
      rescue Grants::Unwritable => e
        grants_unwritable(e)
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
      rescue Grants::Unwritable => e
        grants_unwritable(e)
      end

      # The link a participant opens: web.public_url's with a one-time code
      # for the token in the fragment (LinkCodes, until the grant expires;
      # the page trades it, POST /api/token); else this chi web's LAN address
      # when it has one (the owner may be asking on loopback), else the Host
      # asked; the token traded for the cookie, the session in the fragment.
      def participant_link(req, id, token, expires_at: nil)
        if @public_url
          ttl = expires_at ? [Time.iso8601(expires_at) - @grants.now, 1].max : LinkCodes::OWNER_TTL
          return @public_url.link(@link_codes.issue(kind: :grant, token: token, ttl: ttl), "s=#{id}")
        end

        "#{participant_base(req)}?token=#{token}#s=#{id}"
      end

      # Where a participant's link opens, no token: web.public_url's origin,
      # else this chi web's LAN address, else the Host asked
      # ("http://192.168.1.5:4567/").
      def participant_base(req)
        return "#{@public_url.origin}/" if @public_url

        host = req.get_header("HTTP_HOST").to_s
        port = host[/:(\d+)\z/, 1] || req.port.to_s
        name = @lan ? @lan[:ip] : host.sub(/:\d*\z/, "")
        "http://#{name}:#{port}/"
      end
    end
  end
end
