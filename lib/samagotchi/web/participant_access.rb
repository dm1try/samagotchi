# frozen_string_literal: true

require "json"
require_relative "grants"
require_relative "principal"
require_relative "qr"
require_relative "../archive_store"
require_relative "../client_id"
require_relative "../delivery"
require_relative "../session_inbox"
require_relative "../session_metrics"
require_relative "../parent_report"
require_relative "../participant_messages"
require_relative "../participants"
require_relative "../session"
require_relative "../log"

module Samagotchi
  module Web
    # What a participant (a Web::Grants token) may do in chi web, mixed into
    # App: the gate's lookup of their grant, the refusals that are theirs
    # (token_revoked, token_expired, another session's 404, not_permitted
    # by role), the trimmed answers of the :participant routes, their turns,
    # and the running check that ends their streams when the grant does
    # (what they read is ParticipantReview's). See
    # docs/internals/participants.md.
    module ParticipantAccess
      # A participant's refused routes are audited at most this often per
      # route (a page retrying would fill the log).
      REFUSED_AUDIT_INTERVAL = 60.0

      ENDED = {
        revoked: ["token_revoked", "this review link was revoked by the session's owner"],
        expired: ["token_expired", "this review link expired: ask the session's owner for a new one"]
      }.freeze
      NOT_PERMITTED = Participants::NOT_PERMITTED

      private

      def init_participant_access(grants, state_dir)
        @grants = grants || Grants.new(Grants.path(state_dir: state_dir))
        @participant_mutex = Mutex.new
        @participant_peers = Hash.new { |hash, key| hash[key] = Set.new }
        @participant_refused = {}
        @participant_expired = Set.new
        # enqueued_id => grant id of the turns participants sent through this
        # chi web (their dequeue's check); the oldest go past PARTICIPANT_TURNS_KEPT.
        @participant_turns = {}
      end

      PARTICIPANT_TURNS_KEPT = 1000

      # The participant principal for the first of +tokens+ that is a live
      # grant's, or nil. An ended grant met on the way is kept in the
      # request's env for #token_gate's answer (#grant_ended_response). A
      # grant whose session was archived or is gone is revoked here (archive
      # and delete revoke too; this catches retention's prune and a delete
      # from another process).
      # @return [Principal, nil]
      def participant_principal(req, tokens)
        tokens.each do |token|
          grant = @grants.lookup(token) or next
          grant = settle_grant(grant)
          state = grant.state(@grants.now)
          if state == :active
            req.env[GRANT_TOKEN_ENV] = token
            return Principal.new(kind: :participant, grant: grant)
          end
          req.env[ENDED_GRANT_ENV] ||= [grant, state]
        end
        nil
      end

      GRANT_TOKEN_ENV = "samagotchi.grant_token"
      ENDED_GRANT_ENV = "samagotchi.ended_grant"

      def settle_grant(grant)
        return grant unless grant.active?(@grants.now)

        by = if !File.exist?(Session.session_file(grant.session_id, state_dir: default_state_dir)) then "gone"
             elsif ArchiveStore.archived?(Session.session_dir(grant.session_id, state_dir: default_state_dir)) then "archive"
             end
        return grant unless by

        Participants.revoke(@grants, session_id: grant.session_id, id: grant.id, by: by, state_dir: default_state_dir)
        @grants.find(grant.id) || grant
      end

      # 401 token_revoked / token_expired for an ended grant's token (the
      # page's HTML says the same), nil when none was presented.
      def grant_ended_response(req)
        grant, state = req.env[ENDED_GRANT_ENV]
        return nil unless grant

        audit_expired(grant) if state == :expired
        code, detail = ENDED.fetch(state)
        return error_response(401, code, detail) if req.path_info.start_with?("/api/")

        html_response(401, ENDED_PAGE)
      end

      def audit_expired(grant)
        fresh = @participant_mutex.synchronize { @participant_expired.add?(grant.id) }
        Participants.log(grant.session_id, :expired, state_dir: default_state_dir, participant: grant.id) if fresh
      end

      # A participant's request, past the gate: its use is recorded (the
      # grant's last_used_at, at most once a minute) and a peer not seen
      # since chi web started goes into the audit trail.
      def participant_seen(req, principal)
        grant = principal.grant
        @grants.touch(grant.id)
        peer = req.get_header("REMOTE_ADDR").to_s
        fresh = @participant_mutex.synchronize { @participant_peers[grant.id].add?(peer) }
        return unless fresh

        Participants.log(grant.session_id, :peer, state_dir: default_state_dir, participant: grant.id, ip: peer,
                                                  user_agent: req.get_header("HTTP_USER_AGENT").to_s[0, 200])
      end

      # A participant asking for a session that isn't their grant's: 404 as
      # for one that doesn't exist, so they can't learn which do.
      def other_session?(principal, path, captures)
        return false if principal.owner? || !path.start_with?("/api/sessions/") || captures.empty?

        captures.first != principal.grant.session_id
      end

      def unknown_session(id)
        error_response(404, "not_found", "Session not found: #{id.to_s[0, 80]}")
      end

      # 403 not_permitted, worded for the principal's role; a participant's
      # refusal is audited.
      def not_permitted_for(req, principal)
        return not_permitted if principal.owner?

        audit_refused(req, principal.grant)
        error_response(403, "not_permitted", NOT_PERMITTED)
      end

      def audit_refused(req, grant)
        key = [grant.id, req.request_method, req.path_info]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        due = @participant_mutex.synchronize do
          @participant_refused.delete_if { |_, at| now - at >= REFUSED_AUDIT_INTERVAL } if @participant_refused.size > 256
          last = @participant_refused[key]
          (last.nil? || now - last >= REFUSED_AUDIT_INTERVAL).tap { |fresh| @participant_refused[key] = now if fresh }
        end
        return unless due

        Participants.log(grant.session_id, :refused, state_dir: default_state_dir, participant: grant.id,
                                                     method: req.request_method, path: req.path_info[0, 200],
                                                     reason: "not_permitted")
      end

      # GET /api/info for a participant: what SessionAccess::Remote's
      # check needs (app, version, features), not this machine's pid, cwd
      # or LAN address.
      def participant_info
        json_response(200, { app: "chi-web", version: Samagotchi::VERSION, features: App::INFO_FEATURES })
      end

      # GET /api/sessions/:id for a participant (their grant's session):
      # its title, status and participants, nothing of the conversation.
      def participant_show(id)
        session = @session_class.load(id, state_dir: default_state_dir)
        json_response(200, { session: { id: session.id, title: participant_title(session), status: session.status,
                                        participants: participant_names(id) } })
      end

      # The session's own title, never Session#display_title's fallback (the
      # first prompt's opening words: the conversation).
      def participant_title(session)
        title = session.title.to_s.strip
        title.empty? ? UNTITLED : title
      end

      UNTITLED = "an untitled session"

      def participant_names(id)
        now = @grants.now
        Participants.read(id, state_dir: default_state_dir).select { |entry| entry.active?(now) }
                    .map { |entry| { id: entry.id, name: entry.name, kind: entry.kind, role: entry.role } }
      end

      # ── A participant's turn ──────────────────────────────────────────

      # POST /api/sessions/:id/turn from a participant: a review turn (D6,
      # D10). Of the body only the prompt counts: the author and client id
      # are the grant's (review:<id>), the delivery is always queue, no
      # images, no no_interrupt; the owner's prompt history never sees it.
      # Refused: a line starting ! or / (403 not_permitted: shell lines
      # and commands are the owner's), images (403), their turn limit (429
      # too_many_turns, the Bridge counts) and their cap (429 cap_reached).
      # Every answer is audited (turn: accepted or refused, why).
      def handle_participant_turn(req, id, body)
        grant = principal(req).grant
        prompt = body["prompt"].to_s
        return error_response(400, "missing_fields", "prompt is required") if prompt.strip.empty?

        reason = participant_turn_refusal(grant, prompt, body)
        return participant_turn_refused(grant, prompt, *reason) if reason

        result = SessionManager.deliver_turn(id, prompt: prompt, client_id: ClientId.review(grant.id),
                                                 delivery: Delivery::QUEUE, author: grant.author,
                                                 pending_limit: grant.queue_limit + 1,
                                                 state_dir: @state_dir, manager: @manager,
                                                 bridge: -> { live_bridge_client(id) })
        participant_turn_result(grant, prompt, result)
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # [status, code, detail] for a turn refused before delivery, nil to send it.
      def participant_turn_refusal(grant, prompt, body)
        return [403, "not_permitted", NOT_PERMITTED] if prompt.lstrip.start_with?("!", "/")
        return [403, "not_permitted", NOT_PERMITTED] unless body["images"].nil? || body["images"] == []

        participant_cap_refusal(grant)
      end

      # [429, cap_reached, …] once the grant spent its cap (D7: their turns
      # and the side requests they caused, from the session's saved
      # analytics; a running turn's spend counts from its end, and the
      # worker checks again before a queued one starts), nil before.
      def participant_cap_refusal(grant)
        dir = Session.session_dir(grant.session_id, state_dir: default_state_dir)
        return nil if SessionMetrics.saved_spend(dir, grant.author) < grant.spend_cap

        [429, "cap_reached", ParticipantMessages::CAP_REACHED]
      end

      def participant_turn_refused(grant, prompt, status, code, detail)
        audit_turn(grant, prompt, status: "refused", reason: code)
        error_response(status, code, detail)
      end

      def participant_turn_result(grant, prompt, result)
        case result.status
        when :accepted
          enqueued_id = result.ack["enqueued_id"]
          remember_participant_turn(enqueued_id, grant.id)
          audit_turn(grant, prompt, status: "accepted", enqueued_id: enqueued_id)
          json_response(202, result.ack.merge("via" => result.via.to_s, "delivery" => Delivery::QUEUE))
        when :refused
          audit_turn(grant, prompt, status: "refused", reason: result.ack["error"])
          json_response(result.code, result.ack)
        when :timeout
          audit_turn(grant, prompt, status: "refused", reason: "worker_timeout")
          error_response(504, "worker_timeout", result.detail)
        else error_response(500, "enqueue_failed", "could not write turn input")
        end
      end

      def audit_turn(grant, prompt, status:, **fields)
        Participants.log(grant.session_id, :turn, state_dir: default_state_dir, participant: grant.id,
                                                  chars: prompt.length, status: status, **fields.compact)
      end

      def remember_participant_turn(enqueued_id, grant_id)
        return if enqueued_id.to_s.empty?

        @participant_mutex.synchronize do
          @participant_turns[enqueued_id] = grant_id
          @participant_turns.shift while @participant_turns.size > PARTICIPANT_TURNS_KEPT
        end
      end

      # Whether the turn +enqueued_id+ of session +id+ is +grant+'s: chi
      # web's record of who sent it, else (a chi web restarted since) its
      # waiting input file's author, which only a principal stamps.
      def own_turn?(grant, id, enqueued_id)
        return false unless enqueued_id.is_a?(String) && !enqueued_id.empty?

        sender = @participant_mutex.synchronize { @participant_turns[enqueued_id] }
        return sender == grant.id if sender

        SessionInbox.find_new_input_files(Session.session_dir(id, state_dir: default_state_dir)).any? do |file|
          data = JSON.parse(File.read(file))
          data.is_a?(Hash) && data["enqueued_id"] == enqueued_id && data["author"] == grant.author
        rescue JSON::ParserError, SystemCallError
          false
        end
      end

      # GET /api/sessions/resolve?id= for a participant: their grant's
      # session for its id or a prefix of it, else 404 as for no session
      # (never another session's id, never an ambiguity listing them).
      def participant_resolve(grant, given)
        return json_response(200, { id: grant.session_id }) if grant.session_id.start_with?(given)

        error_response(404, "not_found", "no session #{given[0, 80]}")
      end

      # POST …/wait/prepare for a participant (an agent's chi --remote
      # send --wait, D11): only for a turn of theirs (+turn+, the enqueued
      # id their POST …/turn answered); the body's busy, queue and created
      # don't count.
      def participant_wait_prepare(req, id, body)
        grant = principal(req).grant
        return not_permitted_for(req, principal(req)) unless own_turn?(grant, id, body["turn"])

        start = session_access.prepare_wait(id, session: session_access.show(id), question_id: :pending, turn: body["turn"])
        json_response(200, wait_start_json(id, start))
      end

      # POST …/wait for a participant: only on a turn of theirs, and the
      # answer trimmed to what their turn's reply is (status, text, turn
      # id, a cancel's reason): no file path, no question (an approval or a
      # question their turn raised is the owner's to answer: the status
      # says waiting_for_owner), no origin, no parent strategy. It waits as
      # for a queued turn (theirs always is: never merged), so it never
      # falls back to the next reply past a cursor, which would be anyone's;
      # the body's cursor doesn't count.
      def participant_wait(req, id, options)
        grant = principal(req).grant
        return not_permitted_for(req, principal(req)) unless own_turn?(grant, id, options[:turn])

        options = options.merge(queued: true, cursor: nil)
        session_access.show(id)
        result = session_access.wait_reply(id, **options, poll_interval: @wait_poll_interval,
                                               cancelled: -> { !@server_running.call })
        return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

        json_response(200, participant_wait_json(result))
      end

      def participant_wait_json(result)
        if result.status.to_s == "waiting_for_answer"
          return { status: "waiting_for_owner", detail: ParentReport::WAITING_FOR_OWNER, turn_id: result[:turn_id] }.compact
        end

        text = result[:text]&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        { status: result.status.to_s, text: text, turn_id: result[:turn_id], cancel_reason: result[:cancel_reason] }.compact
      end

      # Whether a principal's stream may go on (the proxy's running check,
      # asked every BridgeClient::STREAM_POLL): while the server runs, and
      # for a participant while their grant works, so a revoke or the expiry
      # ends it within a poll (a chi share revoke in another process too:
      # the grants file is re-read when it changes).
      def stream_running(principal)
        return @server_running if principal.owner?

        id = principal.grant.id
        -> { @server_running.call && @grants.active?(id) }
      end

      # ── The owner's routes ─────────────────────────────────────────────

      # GET /api/sessions/:id/participants, GET /api/participants: the
      # grants (one session's, or every one), in every state, never a token
      # or digest.
      def handle_participants_list(_req, id = nil)
        now = @grants.now
        grants = @grants.list(session_id: id).map { |grant| grant.public_h(now) }
        json_response(200, { participants: id ? with_spend(id, grants) : grants })
      end

      # One session's grants with what each spent and how many turns they
      # ran (its saved analytics: SessionMetrics.saved_by_author), for the
      # owner's participants panel.
      def with_spend(id, grants)
        rows = SessionMetrics.saved_by_author(Session.session_dir(id, state_dir: default_state_dir))
        grants.map do |grant|
          row = rows["p:#{grant[:id]}"] || { turns: 0, cost: 0.0 }
          grant.merge(spend: row[:cost].round(4), turns: row[:turns])
        end
      end

      # POST /api/sessions/:id/participants {name, kind?, ttl? (seconds),
      # cap? (dollars)}: a new grant. The answer carries the token and the
      # link once; chi keeps only its digest.
      def handle_participants_invite(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        ttl = body["ttl"]
        return error_response(400, "invalid_participant", "ttl is a number of seconds") unless ttl.nil? || ttl.is_a?(Integer)

        cap = body["cap"]
        return error_response(400, "invalid_participant", Grants::CAP_RANGE) unless cap.nil? || Grants.cap?(cap)

        issued = Participants.invite(@grants, session_id: id, name: body["name"], kind: (body["kind"] || "human").to_s,
                                              ttl: ttl, cap: cap, state_dir: default_state_dir)
        link = participant_link(req, id, issued.token)
        json_response(201, { participant: issued.grant.public_h(@grants.now), token: issued.token,
                             link: link, lan: !@lan.nil?, qr_svg: QR.svg(link) })
      rescue Grants::Invalid => e
        error_response(400, "invalid_participant", e.message)
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

      def html_response(status, body)
        [status, { "Content-Type" => "text/html; charset=utf-8", "Content-Length" => body.bytesize.to_s,
                   "Cache-Control" => "no-store" }, [body]]
      end

      PAGE_STYLE = <<~CSS
        :root { color-scheme: light dark; }
        body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 30rem; margin: 3rem auto; padding: 0 1rem; }
        .meta { opacity: .75; }
      CSS

      ENDED_PAGE = <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>chi: review link ended</title>
        <style>#{PAGE_STYLE}</style></head>
        <body>
        <h1>chi</h1>
        <p>This review link has expired or was revoked. Ask the session's owner for a new one.</p>
        </body></html>
      HTML
    end
  end
end
