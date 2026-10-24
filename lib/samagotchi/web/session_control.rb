# frozen_string_literal: true

require_relative "../bridge_client"
require_relative "../client_id"
require_relative "../delivery"
require_relative "../image_store"
require_relative "../prompt_history"
require_relative "../session"
require_relative "../session_commands"
require_relative "../session_manager"

module Samagotchi
  module Web
    # The owner's routes that act on a session's worker: answer or dismiss
    # its question, run a command, send a turn (and its images), cancel, stop
    # a task, dequeue a queued turn, stop, restart, archive, unarchive and
    # delete (handle_question_answer … handle_delete), with the refusals they
    # answer (owned_by_repl, owned_by_tui, archive_refused). Included in App:
    # its ROUTES name the handlers, and its helpers (json_response,
    # error_response, parse_json, request_body, relay, not_live,
    # bridge_error, reply_detail, worker_timeout, bridge_client,
    # live_bridge_client, session_owner, record_history, …) and ivars
    # (@manager, @session_class, @state_dir, @hub) answer. A participant's
    # turn goes to ParticipantAccess (handle_participant_turn). See
    # docs/architecture.md (chi web's routes) and docs/internals/remote-sessions.md.
    module SessionControl
      # An uploaded image may be this big before it is downscaled.
      MAX_IMAGE_UPLOAD_BYTES = 20 * 1024 * 1024

      IMAGE_NAME_RE = /\A[0-9a-f]{16}\.(png|jpe?g|gif|webp)\z/

      IMAGE_TYPES = { "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif",
                      "webp" => "image/webp" }.freeze

      # POST /stop waits this long for the worker to let go of the session
      # when the body names no wait (the page's Stop: it shows the stop at
      # once, and a Rack thread isn't held for it). A CLI through --remote
      # sends its own, SessionManager::STOP_WAIT at most, so chi sessions
      # stop waits as long as here.
      STOP_WAIT_SECONDS = 2.0

      # A task id as TaskRuntime.generate_task_id makes it.
      TASK_ID = /\A\d{14}-\h{8}\z/

      private

      def handle_question_answer(req, id)
        session = @session_class.load(id, state_dir: default_state_dir) rescue nil
        return error_response(404, "not_found", "Session not found: #{id}") unless session

        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        qid = body["id"]
        return error_response(400, "missing_fields", "id is required") if qid.to_s.strip.empty?

        # client_id: only chi answer's (a parent agent's answer, which the
        # worker holds to its guardrails.parent_answers) is passed on; any
        # other is dropped, so a forward can only tighten (an answer never
        # passes for the user's own by it).
        client_id = body["client_id"] == ClientId::CLI_ANSWER ? ClientId::CLI_ANSWER : nil
        request = once_more_on_late do |client|
          client.answer(id: qid, selected: body["selected"], freeform: body["freeform"], client_id: client_id)
        end
        relay(id, bridge_client(id), request, what: "the answer was not sent", cant: "answer questions") do |reply|
          case reply.status
          when 200 then json_response(200, { status: "answered", session_id: id, id: qid })
          # Another client answered first (or the question was cancelled).
          when 409 then error_response(409, "question_not_pending", reply_detail(reply, "question not pending"))
          when 400 then error_response(400, "invalid_answer", reply_detail(reply, "answer rejected"))
          # The worker's guardrails.parent_answers refused a parent's option.
          when 403 then json_response(403, { error: "parent_answer_refused", reason: reply.json&.dig("reason"),
                                             detail: reply_detail(reply, "the worker refused that option") })
          end
        end
      end

      # A request to the worker sent once more when the worker dropped it as
      # past its deadline (408), as chi answer does on this machine
      # (SessionAccess::Local#answer); a second 408 is #relay's 504
      # worker_timeout. The question stays open either way.
      def once_more_on_late
        lambda do |client|
          reply = yield client
          reply.status == 408 ? yield(client) : reply
        end
      end

      # Leave the pending question unanswered (the card's Dismiss). A question
      # only exists while its worker waits on it, so this needs a live bridge.
      def handle_question_dismiss(req, id)
        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        qid = body["id"].to_s
        return error_response(400, "missing_fields", "id is required") if qid.strip.empty?

        request = once_more_on_late { |client| client.dismiss_question(id: qid) }
        relay(id, bridge_client(id), request, what: "the question was not dismissed", cant: "dismiss questions") do |reply|
          case reply.status
          when 200 then json_response(200, { status: "dismissed", session_id: id, id: qid })
          when 409
            # The step-limit question can't be left unanswered.
            code = reply.json&.dig("error") == "not_dismissable" ? "not_dismissable" : "question_not_pending"
            error_response(409, code, reply_detail(reply, "question not pending"))
          end
        end
      end

      # A session command typed in the composer (/model, /models, !rollback,
      # !cmd, /continue): the worker runs it (woken as for a turn) and every
      # UI gets its :command_ran. Needs the worker's Bridge.
      def handle_command(req, id)
        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        line = body["line"].to_s.strip
        return error_response(400, "missing_fields", "line is required") if line.empty?

        @manager.resume_session(id, state_dir: @state_dir)
        # card: a card's action; its command events say so (no echo).
        request = ->(client) { client.post_command(line: line, client_id: body["client_id"], card: body["card"] == true) }
        relay(id, live_bridge_client(id), request, what: "the command was not run", cant: "run commands") do |reply|
          case reply.status
          when 202
            record_history(body, line) if PromptHistory.shell_line?(line)
            json_response(202, reply.json || { status: "accepted" })
          when 400
            # One of this chi's own commands the worker doesn't know: it runs an
            # older chi. command: which one, so a remote TUI names it as its
            # Bridge's own 400 unknown_command would (WebBridgeClient).
            name = reply.json&.dig("error") == "unknown_command" && SessionCommands.builtin_name(line)
            next older_worker_command(id, name) if name

            error_response(400, reply.json&.dig("error") || "unknown_command", reply_detail(reply, "not a session command"))
          end
        end
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # 501 not_supported for a builtin +name+ ("/title") the worker lacks.
      def older_worker_command(id, name)
        words = BridgeClient.stale_worker_message(id, cant: "run #{name}")
        json_response(501, { error: "not_supported", detail: words, message: words, command: name })
      end

      def handle_turn(req, id)
        body = parse_json(request_body(req))
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end
        # A participant's review turn: its own path, which takes from the
        # body only the prompt (ParticipantAccess#handle_participant_turn).
        return handle_participant_turn(req, id, body) unless principal(req).owner?

        prompt = body["prompt"] || body[:prompt]
        client_id = body["client_id"] || body[:client_id]
        if prompt.to_s.strip.empty?
          return error_response(400, "missing_fields", "prompt is required")
        end

        images = turn_images(id, body["images"])
        return error_response(400, "bad_images", images) if images.is_a?(String)

        delivery = body["delivery"] || body[:delivery]
        if (refused = Delivery.refusal(delivery))
          return error_response(400, refused[:error], refused[:detail])
        end

        refused = turn_refusal(id, body, prompt.to_s, images)
        return refused if refused

        # no_interrupt: an attached TUI's --no-interrupt (chi --remote --attach).
        # author: the principal's (nil for the owner), never the body's.
        result = SessionManager.deliver_turn(id, prompt: prompt.to_s, client_id: client_id, images: images,
                                                 delivery: delivery, no_interrupt: body["no_interrupt"] == true,
                                                 author: principal(req).author,
                                                 state_dir: @state_dir, manager: @manager,
                                                 bridge: -> { live_bridge_client(id) })
        case result.status
        when :accepted
          record_history(body, prompt)
          # via: bridge or file (the worker was gone: its input file), which
          # names the turn a remote chi send --wait follows (WaitTarget).
          json_response(202, result.ack.merge("via" => result.via.to_s))
        when :refused then json_response(result.code, result.ack)
        when :timeout then error_response(504, "worker_timeout", result.detail)
        else error_response(500, "enqueue_failed", "could not write turn input")
        end
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # A turn refused before it goes in, as chi send refuses it on its own
      # machine: a chi send line #parent_gate refuses (the session's own
      # parent_answers), and with check_vision: true images to a model known
      # not to take them (422 no_vision). The page sends neither.
      # @return [Array, nil] the response, or nil to go on
      def turn_refusal(id, body, prompt, images)
        vision = body["check_vision"] == true && !images.empty?
        return nil unless vision || App::CLI_SEND_IDS.include?(body["client_id"])

        session = @session_class.load(id, state_dir: default_state_dir)
        refused = parent_gate(prompt, client_id: body["client_id"], values: [session.parent_answers])
        return refused if refused

        vision ? vision_refused(session.model_name, session.model_typed) : nil
      end

      # A turn's images as [{file:, name:}] (refs to uploads already in the
      # session's images/), or a String saying what's wrong. Never a path.
      def turn_images(id, raw)
        return [] if raw.nil?

        session_dir = image_session_dir(id)
        return "unknown session" unless session_dir

        ImageStore.check_refs(session_dir, raw)
      end

      # The session's folder, or nil for an id that isn't one.
      def image_session_dir(id)
        return nil unless App::SESSION_ID_RE.match?(id.to_s)

        @session_class.load(id, state_dir: default_state_dir)
        Session.session_dir(id, state_dir: default_state_dir)
      rescue ArgumentError
        nil
      end

      # POST /api/sessions/:id/images: the raw image as the body (a paste or
      # a drop), ?name= for its file name. Stored like any other image
      # (converted, downscaled); answers the ref the turn then names.
      def handle_image_upload(req, id)
        session_dir = image_session_dir(id)
        return error_response(404, "not_found", "unknown session") unless session_dir

        length = req.content_length.to_i
        if length > MAX_IMAGE_UPLOAD_BYTES
          return error_response(413, "too_large", "an image may be up to #{MAX_IMAGE_UPLOAD_BYTES / 1024 / 1024} MB")
        end

        bytes = request_body(req, MAX_IMAGE_UPLOAD_BYTES + 1).to_s.b
        if bytes.bytesize > MAX_IMAGE_UPLOAD_BYTES
          return error_response(413, "too_large", "an image may be up to #{MAX_IMAGE_UPLOAD_BYTES / 1024 / 1024} MB")
        end

        name = File.basename(req.params["name"].to_s)[0, 120]
        ref = ImageStore.ingest(session_dir, bytes: bytes, name: name.empty? ? "image" : name, source: "user")
        json_response(201, ref)
      rescue ImageStore::Error => e
        error_response(422, "bad_image", e.message)
      end

      # GET /api/sessions/:id/images/<hash>.<ext>: a stored image (only
      # raster types; never svg), for the page's thumbnails.
      def handle_image(_req, id, name)
        session_dir = image_session_dir(id)
        return not_found(path: "images/#{name}") unless session_dir && IMAGE_NAME_RE.match?(name.to_s)

        path = File.join(session_dir, ImageStore::DIR, name)
        return not_found(path: "images/#{name}") unless File.file?(path) && !File.symlink?(path)

        body = File.binread(path)
        [200, { "Content-Type" => IMAGE_TYPES.fetch(File.extname(name).delete(".")), "Content-Length" => body.bytesize.to_s,
                "X-Content-Type-Options" => "nosniff", "Cache-Control" => "private, max-age=86400" }, [body]]
      end

      # The Bridge decides the reason (Bridge::CANCEL_REASONS; anything
      # else is manual) and the reply echoes its choice. No reason: user.
      def handle_cancel(req, id)
        @session_class.load(id, state_dir: default_state_dir)

        parsed = parse_json(request_body(req))
        reason = (parsed["reason"] if parsed.is_a?(Hash)).to_s.strip
        reason = "user" if reason.empty?

        request = ->(client) { client.cancel(reason: reason) }
        relay(id, bridge_client(id), request, what: "the turn was not cancelled", cant: "cancel turns") do |reply|
          case reply.status
          when 202
            json_response(202, { status: "cancel_requested", session_id: id, reason: reply.json&.dig("reason"), via: "bridge" })
          # No active turn to cancel.
          when 409 then json_response(409, { error: "not_running", detail: "no active turn to cancel", session_id: id })
          end
        end
      end

      # The stop-task button: the worker stops the task as the user
      # (Bridge#handle_task_stop) and its task_wait returns. Its own 404
      # (not this conversation's task) and 409 (already ended) pass through;
      # a 404 from a worker without the route is the stale worker's 501.
      def handle_task_stop(_req, id, task_id)
        return error_response(400, "invalid_task_id", "not a task id: #{task_id.to_s[0, 80]}") unless TASK_ID.match?(task_id)

        @session_class.load(id, state_dir: default_state_dir)
        request = ->(client) { client.stop_task(task_id) }
        relay(id, bridge_client(id), request, what: "the task was not stopped", cant: "stop tasks") do |reply|
          body = reply.json || {}
          case reply.status
          when 200 then json_response(200, { status: body["status"], stop_reason: body["stop_reason"], task_id: task_id, session_id: id })
          when 404 then (error_response(404, "task_not_found", "no task #{task_id} in this conversation") if body["error"] == "task_not_found")
          when 409 then json_response(409, { error: "not_running", status: body["status"], task_id: task_id, session_id: id })
          end
        end
      end

      # POST /api/sessions/:id/turn/:enqueued_id/dequeue {client_id?}: the ×
      # on a queued bubble takes the message back before it runs
      # (Bridge#handle_dequeue_turn). Straight to the live worker, never
      # through deliver_turn: a removal must not wake one, and a stopped
      # worker's queued file is the next worker's (503 not_live). 200
      # {status, enqueued_id, prompt}; 409 already_started / not_queued and
      # 404 unknown_enqueued_id pass through; the rest as every relay.
      def handle_dequeue_turn(req, id, enqueued_id)
        @session_class.load(id, state_dir: default_state_dir)
        parsed = parse_json(request_body(req))
        client_id = (parsed["client_id"] if parsed.is_a?(Hash))
        # A participant takes back only their own queued turns, by chi web's
        # record of who sent each (never a body's client id).
        unless (who = principal(req)).owner?
          return not_permitted_for(req, who) unless own_turn?(who.grant, id, enqueued_id)

          client_id = ClientId.review(who.grant.id)
        end

        request = ->(client) { client.dequeue(enqueued_id: enqueued_id, client_id: client_id) }
        relay(id, bridge_client(id), request, what: "the message was not removed", cant: "remove queued messages") do |reply|
          body = reply.json || {}
          case reply.status
          when 200 then json_response(200, { status: body["status"], enqueued_id: enqueued_id, prompt: body["prompt"].to_s, session_id: id })
          when 409 then json_response(409, { error: body["error"] || "already_started", detail: body["detail"], enqueued_id: enqueued_id, session_id: id }.compact)
          when 404
            json_response(404, { error: "unknown_enqueued_id", enqueued_id: enqueued_id, session_id: id }) if body["error"] == "unknown_enqueued_id"
          end
        end
      end

      # POST /api/sessions/:id/stop {wait?}: 200 {status: "stopped",
      # session_id, released}: released, whether the worker let go of the
      # session within the wait (STOP_WAIT_SECONDS, or the body's seconds up
      # to SessionManager::STOP_WAIT: chi sessions stop's two wordings); 409
      # owned_by_tui.
      def handle_stop(req, id)
        # Bounded, so a Rack thread isn't held long; a worker still exiting
        # after it just means an immediate resume finds it (rare).
        released = @manager.stop_session(id, state_dir: @state_dir, wait: stop_wait(req))
        @hub&.touch(id)
        json_response(200, { status: "stopped", session_id: id, released: released == true })
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # The body's wait (a number of seconds), capped at
      # SessionManager::STOP_WAIT; STOP_WAIT_SECONDS without one.
      def stop_wait(req)
        body = parse_json(request_body(req, 4096))
        wait = body["wait"] if body.is_a?(Hash)
        wait.is_a?(Numeric) && wait.positive? ? [wait, SessionManager::STOP_WAIT].min : STOP_WAIT_SECONDS
      end

      # POST /api/sessions/:id/restart: hand the session to a new worker on
      # the newest chi installed (SessionManager.restart_session). 200
      # {status: "restarted", session_id, from_version, version} (version nil:
      # the new worker is still starting; its bridge_up follows); 409
      # {error: "held" | "not_running" | "unsupported" | "failed", reason, detail} in words; 409
      # owned_by_tui; 404.
      def handle_restart(_req, id)
        result = @manager.restart_session(id, state_dir: @state_dir, client_id: ClientId::WEB_RESTART)
        @hub&.touch(id)
        json_response(200, { status: "restarted", session_id: id, from_version: result.from_version,
                             version: result.version })
      rescue SessionManager::RestartRefused => e
        error = %i[not_running unsupported failed].include?(e.reason) ? e.reason.to_s : "held"
        refusal_response(409, error, e, reason: e.reason.to_s, session_id: id, version: e.version)
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # POST /api/sessions/:id/archive: hide it (and its delegates) from the
      # lists, keep it for good. A live idle worker is stopped first; a turn
      # running in it or a delegate, a chi REPL's session and a scratch one
      # are refused (409).
      def handle_archive(_req, id)
        result = @manager.archive_session(id, state_dir: @state_dir, wait: STOP_WAIT_SECONDS)
        (result[:archived] + result[:discarded]).each { |sid| @hub&.touch(sid) }
        json_response(200, { status: "archived", session_id: result[:id], archived: result[:archived],
                             stopped: result[:stopped], discarded: result[:discarded] })
      rescue SessionManager::OwnedByTUI => e
        owned_by_repl(id, e)
      rescue SessionManager::ArchiveRefused => e
        archive_refused(e)
      end

      # POST /api/sessions/:id/unarchive: back to the lists, delegates too.
      def handle_unarchive(_req, id)
        result = @manager.unarchive_session(id, state_dir: @state_dir)
        result[:unarchived].each { |sid| @hub&.touch(sid) }
        json_response(200, { status: "unarchived", session_id: result[:id], unarchived: result[:unarchived] })
      end

      # DELETE /api/sessions/:id?force=true: the session for good. With
      # force a live worker is stopped first (the page sends it: its confirm
      # says so); without it a live worker's session is refused, 409
      # worker_running, as chi sessions delete without --force. A chi REPL's
      # session is always refused.
      def handle_delete(req, id)
        result = @manager.delete_session(id, state_dir: @state_dir, stop: truthy_param?(req.params["force"]),
                                             wait: STOP_WAIT_SECONDS)
        @hub&.touch(result[:id])
        json_response(200, { status: "deleted", session_id: result[:id], stopped: result[:stopped] })
      rescue SessionManager::OwnedByTUI => e
        owned_by_repl(id, e)
      rescue SessionManager::DeleteRefused => e
        detail = e.reason == :still_stopping ? "#{e.message}; try again in a moment" : e.message
        refusal_response(409, e.reason.to_s, e, detail: detail, session_id: e.session_id, reason: e.reason.to_s)
      end

      # 409 owned_by_tui in the words a refused archive, delete or continue
      # shows (stop, restart, a turn and a command show OwnedByTUI's own).
      def owned_by_repl(id, error = nil)
        named = SessionManager::OwnedByTUI.new(id)
        error ||= named
        refusal_response(409, "owned_by_tui", error, detail: named.message, session_id: error.session_id)
      end

      # 409 owned_by_tui in OwnedByTUI's own words (stop, restart, a turn, a
      # command).
      def owned_by_tui(error) = refusal_response(409, "owned_by_tui", error, session_id: error.session_id)

      # 409 scratch or busy (every other reason: a turn, a queued prompt, an
      # open step-limit question, in it or a delegate, +busy_id+), with the
      # reason for a remote client.
      def archive_refused(error)
        refusal_response(409, error.reason == :scratch ? "scratch" : "busy", error, session_id: error.session_id,
                                                                                  reason: error.reason.to_s, busy_id: error.busy_id)
      end
    end
  end
end
