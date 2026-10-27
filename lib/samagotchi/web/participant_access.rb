# frozen_string_literal: true

require "json"
require_relative "grants"
require_relative "principal"
require_relative "participant_view"
require_relative "../archive_store"
require_relative "../client_id"
require_relative "../delivery"
require_relative "../session_inbox"
require_relative "../session_metrics"
require_relative "../parent_report"
require_relative "../participant_messages"
require_relative "../participants"
require_relative "../session"
require_relative "../turn_checkpoint"
require_relative "../verify_fresh"
require_relative "../log"

module Samagotchi
  module Web
    # What a participant (a Web::Grants token) may do in chi web, mixed into
    # App: the gate's lookup of their grant, the refusals that are theirs
    # (token_revoked, token_expired with its ended page, token_bound for a
    # link bound to another account, another session's
    # 404, not_permitted by role), the trimmed answers of their own routes
    # (info, the session, resolve, a wait on their turn), their turns, and
    # the running check that ends their streams when the grant does. What
    # they read is ParticipantReview's; the owner's routes for them (invite,
    # list, revoke, cap, Apply) are ParticipantsAdmin's. See
    # docs/internals/participants.md.
    module ParticipantAccess
      # A participant's refused routes are audited at most this often per
      # route (a page retrying would fill the log).
      REFUSED_AUDIT_INTERVAL = 60.0
      # At most this many refusals a minute are remembered per reason, so
      # audited: rotating paths or headers can't grow the map or the audit
      # file without bound (as App::REFUSED_LOG_KEYS for the log), nor one
      # reason's flood silence another's.
      REFUSED_AUDIT_KEYS = 256

      ENDED = {
        revoked: ["token_revoked", ParticipantMessages::TOKEN_REVOKED],
        expired: ["token_expired", ParticipantMessages::TOKEN_EXPIRED]
      }.freeze
      NOT_PERMITTED = ParticipantMessages::NOT_PERMITTED

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
      # from another process). A grant bound to an identity (Grant#identity)
      # is honoured only on a proxied request with that identity
      # (ProxyGate): never on the LAN or this machine.
      # @param identity [String, nil] the proxied request's identity
      # @return [Principal, nil]
      def participant_principal(req, tokens, identity: nil, proxied: false)
        tokens.each do |token|
          grant = @grants.lookup(token) or next
          unless bound_ok?(grant, identity, proxied)
            refuse_bound(req, grant, identity)
            next
          end
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
      BOUND_GRANT_ENV = "samagotchi.bound_grant"

      # Whether +grant+ may be used by this request: an unbound one anywhere,
      # a bound one only proxied and only for its identity (the one check,
      # for the gate and for a link code's trade).
      def bound_ok?(grant, identity, proxied)
        grant.identity.nil? || (proxied && !identity.nil? && identity == grant.identity)
      end

      # A bound grant presented by another identity, or not through the
      # proxy: #grant_bound_response answers it (token_bound).
      def refuse_bound(req, grant, identity)
        req.env[ProxyGate::REFUSED_ENV] = "grant #{grant.id} is bound to another identity than #{identity || "(none)"}"
        req.env[BOUND_GRANT_ENV] ||= [grant, identity]
      end

      # 401 token_bound for a bound grant's token (or link code) presented
      # without its identity (the page's HTML says the same words), nil when
      # none was: logged as a refusal and audited in the grant's session.
      def grant_bound_response(req)
        grant, identity = req.env[BOUND_GRANT_ENV]
        return nil unless grant

        log_refused(refused_peer(req), req.path_info, "grant #{grant.id} is bound to another identity than #{identity || "(none)"}")
        audit_refused(req, grant, reason: "token_bound", per_route: false, identity: (identity || "(none)")[0, 200])
        detail = ParticipantMessages::TOKEN_BOUND
        return error_response(401, "token_bound", detail) if req.path_info.start_with?("/api/")

        html_response(401, BOUND_PAGE.sub(ENDED_SENTENCE) { "#{detail[0].upcase}#{detail[1..]}." })
      end

      def settle_grant(grant)
        return grant unless grant.active?(@grants.now)

        by = if !File.exist?(Session.session_file(grant.session_id, state_dir: default_state_dir)) then "gone"
             elsif ArchiveStore.archived?(Session.session_dir(grant.session_id, state_dir: default_state_dir)) then "archive"
             end
        return grant unless by

        Participants.revoke(@grants, session_id: grant.session_id, id: grant.id, by: by, state_dir: default_state_dir)
        @grants.find(grant.id) || grant
      rescue Grants::Unwritable
        # A store this chi can't write (a newer chi's): refused all the same.
        grant.with(revoked_at: @grants.now.utc.iso8601, revoked_by: by)
      end

      # 401 token_revoked / token_expired for an ended grant's token (the
      # page's HTML says the same words), nil when none was presented.
      def grant_ended_response(req)
        grant, state = req.env[ENDED_GRANT_ENV]
        return nil unless grant

        audit_expired(grant) if state == :expired
        code, detail = ENDED.fetch(state)
        return error_response(401, code, detail) if req.path_info.start_with?("/api/")

        html_response(401, ENDED_PAGE.sub(ENDED_SENTENCE) { "#{detail[0].upcase}#{detail[1..]}." })
      end

      def audit_expired(grant)
        fresh = @participant_mutex.synchronize { @participant_expired.add?(grant.id) }
        Participants.log(grant.session_id, :expired, state_dir: default_state_dir, participant: grant.id) if fresh
      end

      # A participant's request, past the gate: its use is recorded (the
      # grant's last_used_at, at most once a minute) and a peer not seen
      # since chi web started goes into the audit trail. Behind a proxy
      # every peer is 127.0.0.1: there the peer is the client's identity
      # (else the proxy's X-Forwarded-For hop, #refused_peer), and the line
      # names the identity.
      def participant_seen(req, principal)
        grant = principal.grant
        @grants.touch(grant.id)
        peer = refused_peer(req)
        fresh = @participant_mutex.synchronize { @participant_peers[grant.id].add?(peer) }
        return unless fresh

        fields = { ip: req.get_header("REMOTE_ADDR").to_s, user_agent: req.get_header("HTTP_USER_AGENT").to_s[0, 200] }
        if proxied?(req)
          state, identity = proxy_identity(req)
          fields[:identity] = identity if state == :ok
          fields[:peer] = peer
        end
        Participants.log(grant.session_id, :peer, state_dir: default_state_dir, participant: grant.id, **fields)
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

      # 403 not_permitted for a participant (the owner is never refused by
      # role), audited.
      def not_permitted_for(req, principal)
        audit_refused(req, principal.grant)
        error_response(403, "not_permitted", NOT_PERMITTED)
      end

      # +reason+ and +fields+ go into the line (a bound refusal names the
      # identity that presented it). Once a minute per route for
      # not_permitted; once a minute per grant and identity for a bound
      # refusal, whatever the path (+per_route+ false); at most
      # REFUSED_AUDIT_KEYS keys a minute.
      def audit_refused(req, grant, reason: "not_permitted", per_route: true, **fields)
        key = per_route ? [grant.id, req.request_method, req.path_info, reason, fields] : [grant.id, reason, fields]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        due = @participant_mutex.synchronize do
          seen = (@participant_refused[reason] ||= {})
          seen.delete_if { |_, at| now - at >= REFUSED_AUDIT_INTERVAL } if seen.size > 64
          next false if seen.size >= REFUSED_AUDIT_KEYS && !seen.key?(key)

          last = seen[key]
          (last.nil? || now - last >= REFUSED_AUDIT_INTERVAL).tap { |fresh| seen[key] = now if fresh }
        end
        return unless due

        Participants.log(grant.session_id, :refused, state_dir: default_state_dir, participant: grant.id,
                                                     method: req.request_method, path: req.path_info[0, 200],
                                                     reason: reason, **fields)
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
        return title unless title.empty?

        # A review session's subjects are what participants read anyway.
        subjects = session.review&.subjects || []
        return UNTITLED if subjects.empty?

        "review of #{subjects.first}#{" +#{subjects.size - 1}" if subjects.size > 1}"
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

        verify = VerifyAnchor.from(body["verify"])
        result = SessionManager.deliver_turn(id, prompt: prompt, client_id: ClientId.review(grant.id),
                                                 delivery: Delivery::QUEUE, author: grant.author,
                                                 verify: verify,
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
      # analytics, and their Verify fresh children's; a running turn's
      # spend counts from its end, and the worker checks again before a
      # queued one starts), nil before.
      def participant_cap_refusal(grant)
        return nil if participant_saved_spend(grant) < grant.spend_cap

        [429, "cap_reached", ParticipantMessages::CAP_REACHED]
      end

      # What +grant+'s participant spent, saved: in the session and in
      # their Verify fresh children (VerifyFresh.children_spend).
      def participant_saved_spend(grant)
        dir = Session.session_dir(grant.session_id, state_dir: default_state_dir)
        SessionMetrics.saved_spend(dir, grant.author) +
          VerifyFresh.children_spend(grant.session_id, grant.author, state_dir: default_state_dir)
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
      # web's record of who sent it, else (a chi web restarted since) the
      # author the session's files keep for it (#turn_author), which only a
      # principal stamps.
      def own_turn?(grant, id, enqueued_id)
        return false unless enqueued_id.is_a?(String) && !enqueued_id.empty?

        sender = @participant_mutex.synchronize { @participant_turns[enqueued_id] }
        return sender == grant.id if sender

        turn_author(id, enqueued_id) == grant.author
      end

      # Who queued the turn +enqueued_id+, as the session's files say: its
      # input file's author while it waits or runs (the claimed
      # *.json.processing stays until the turn ends), then the turn's end:
      # last_turn's author, or its settled record's (a refused turn's).
      # nil for the owner's turn, or one nothing names.
      def turn_author(id, enqueued_id)
        dir = Session.session_dir(id, state_dir: default_state_dir)
        files = SessionInbox.find_new_input_files(dir) + SessionInbox.claimed_input_files(dir)
        files.each do |file|
          data = JSON.parse(File.read(file))
          return data["author"] if data.is_a?(Hash) && data["enqueued_id"] == enqueued_id
        rescue JSON::ParserError, SystemCallError
          next
        end
        last = session_access.show(id).last_turn
        return last.author if last&.enqueued_id == enqueued_id

        TurnCheckpoint.settled_turn(dir, enqueued_id)&.author
      rescue ArgumentError, JSON::ParserError, SystemCallError
        nil
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
      # don't count. The answer is what their wait on that turn needs
      # (SendCommand's WaitTarget.after with the turn asked, the wait's
      # baseline), never the owner's wait state: the last turn's end (the
      # baseline's last_turn), whether their turn is known, whether a worker
      # runs it, and last_turn_id only when it is their turn. No cursor
      # (their wait ignores it), message count, pending question or running
      # turn.
      def participant_wait_prepare(req, id, body)
        grant = principal(req).grant
        turn = body["turn"]
        return not_permitted_for(req, principal(req)) unless own_turn?(grant, id, turn)

        start = session_access.prepare_wait(id, session: session_access.show(id), question_id: :pending, turn: turn)
        json_response(200, { session_id: id, baseline: { last_turn: start.baseline.last_turn }.compact,
                             known_turn: start.known_turn, live: start.live,
                             last_turn_id: (turn if start.last_turn_id == turn) }.compact)
      end

      # POST …/wait for a participant: only on a turn of theirs, and the
      # answer trimmed to what their turn's reply is (status, text, turn
      # id, a cancel's reason): no file path, no question (an approval or a
      # question their turn raised is the owner's to answer: the status
      # says waiting_for_owner), no origin, no parent strategy. It waits as
      # for a queued turn (theirs always is: never merged), so it never
      # falls back to the next reply past a cursor, which would be anyone's;
      # the body's cursor doesn't count. A revoke or the expiry ends a wait
      # already running (the gate checked the grant when it began): 401
      # token_revoked / token_expired, as their next request would get.
      def participant_wait(req, id, options)
        grant = principal(req).grant
        return not_permitted_for(req, principal(req)) unless own_turn?(grant, id, options[:turn])

        options = options.merge(queued: true, cursor: nil, running_look: nil)
        session = session_access.show(id)
        result = session_access.wait_reply(id, **options, poll_interval: @wait_poll_interval,
                                               cancelled: -> { !@server_running.call || !@grants.active?(grant.id) })
        if result.status == :canceled
          current = @grants.find(grant.id)
          return error_response(401, *ENDED.fetch(:revoked)) unless current

          ended = current.state(@grants.now)
          return error_response(401, *ENDED.fetch(ended)) if ENDED.key?(ended)

          return error_response(503, "server_stopping", "chi web is stopping; wait again")
        end

        json_response(200, participant_wait_json(result, participant_viewer(req, session)))
      end

      # The wait's answer as a participant reads it: their reply through
      # ParticipantView.reply (as the stream and the review show it), any
      # other text (an error's exception, a failed turn's summary) the fixed
      # TURN_FAILED.
      def participant_wait_json(result, viewer)
        if result.status.to_s == "waiting_for_answer"
          return { status: "waiting_for_owner", detail: ParentReport::WAITING_FOR_OWNER, turn_id: result[:turn_id] }.compact
        end

        text = result[:text]&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        text = result.status == :done ? ParticipantView.reply(text, viewer) : ParticipantMessages::TURN_FAILED if text
        { status: result.status.to_s, text: text, turn_id: result[:turn_id], outcome: result[:outcome],
          cancel_reason: result[:cancel_reason] }.compact
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

      def html_response(status, body)
        [status, { "Content-Type" => "text/html; charset=utf-8", "Content-Length" => body.bytesize.to_s,
                   "Cache-Control" => "no-store" }, [body]]
      end

      PAGE_STYLE = <<~CSS
        :root { color-scheme: light dark; }
        body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 30rem; margin: 3rem auto; padding: 0 1rem; }
        .meta { opacity: .75; }
      CSS

      ENDED_SENTENCE = "{sentence}"
      ENDED_PAGE = <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>chi: review link ended</title>
        <style>#{PAGE_STYLE}</style></head>
        <body>
        <h1>chi</h1>
        <p id="ended">{sentence}</p>
        <script>
          if (/[#&]code=/.test(location.hash)) document.getElementById("ended").hidden = true;
        </script>
        <p id="trade" hidden></p>
        <script type="module">
          const ended = document.getElementById("ended");
          import("/token_fragment.js").then(({ tradeFragmentCode }) => tradeFragmentCode({
            onRefused: (words) => {
              const line = document.getElementById("trade");
              line.textContent = words;
              line.hidden = false;
              ended.hidden = false;
            }
          })).catch(() => { ended.hidden = false; });
        </script>
        </body></html>
      HTML
      BOUND_PAGE = ENDED_PAGE.sub("<title>chi: review link ended</title>", "<title>chi: review link for another account</title>")
    end
  end
end
