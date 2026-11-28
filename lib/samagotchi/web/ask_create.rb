# frozen_string_literal: true

require_relative "../client_id"
require_relative "../config"
require_relative "../guardrails/parent_policy"
require_relative "../model_profile"
require_relative "../session"
require_relative "../session_inbox"
require_relative "../session_manager"
require_relative "last_ask"
require_relative "start_dir"

module Samagotchi
  module Web
    # POST /api/sessions answering its first turn (docs/thin-clients.md "A
    # new session in one call"): a create with any of reply_for, timeout or
    # request_id (ASK_FIELDS) spawns the session idle, its prompt as the
    # preview, then runs the same SessionAccess::Ask an /ask runs
    # (AskRoutes#run_ask), all within one ASK_MAX_SECONDS deadline. Included
    # in App beside SessionCreate (which hands such a body here) and
    # AskRoutes, whose readers and response builders it uses.
    module AskCreate
      # The body fields that make a create answer its first turn.
      ASK_FIELDS = %w[reply_for timeout request_id].freeze
      # GET /api/info's feature: this chi web's create answers its first turn.
      FEATURE = "ask_create"
      INLINE_ONLY = "an answered create starts a new session with a prompt: leave out idle and continues"

      # One lock per derived session id, held over the check, the spawn and
      # the Ask: two same-request_id creates at once make one session and
      # one turn. chi web is the only creator of these ids.
      LOCKS = {}
      LOCKS_GUARD = Mutex.new

      def self.inline?(body) = ASK_FIELDS.any? { |key| body.key?(key) }

      # The block under +id+'s lock (none for nil), the entry dropped once
      # nobody holds or waits for it.
      def self.locked(id, &)
        return yield if id.nil?

        entry = LOCKS_GUARD.synchronize { (LOCKS[id] ||= [Mutex.new, 0]).tap { |e| e[1] += 1 } }
        begin
          entry[0].synchronize(&)
        ensure
          LOCKS_GUARD.synchronize { LOCKS.delete(id) if (entry[1] -= 1).zero? }
        end
      end

      private

      # The inline create: the ask's fields read first (a bad timeout,
      # request_id or reply_for, a UI-only command, an oversize prompt spawn
      # nothing), then the folder (the body's dir, else web.ask_dir, else
      # chi web's start folder) and every check a create makes, then the
      # idle spawn (with a request_id, at the id it names: a retry finds it
      # and spawns nothing) and the Ask. 201 with the ask's answer
      # (AskRoutes#ask_response's fields; session_id, created, model_warning,
      # parent_answers_warning); a refusal after the spawn keeps its code
      # and carries session_id and created. The owner's own create is their
      # `last` (LastAsk), refused or not.
      def handle_ask_create(body, deadline)
        if body["idle"] == true || body.key?("continues")
          return error_response(400, "invalid_ask", INLINE_ONLY)
        end

        prompt, client_id, options, reply_for, error = ask_fields(body, id: nil)
        return error if error

        dir, error = ask_create_dir(body)
        return error if error

        folder, parent_answers, error = create_fields(body, prompt, dir: dir)
        return error if error

        request_id = options[:request_id]
        session_id = request_id && SessionInbox.enqueued_id_for("create:#{request_id}")
        AskCreate.locked(session_id) do
          session, error = ask_create_spawn(body, prompt, folder, session_id)
          return error if error

          sid = session&.id || session_id
          @hub&.touch(sid)
          extra = { session_id: sid, created: !session.nil?, model_warning: session&.model_warning,
                    parent_answers_warning: Guardrails::ParentPolicy.capped_note(parent_answers) }
          response = ask_create_run(sid, prompt, client_id, options, reply_for, deadline, body, extra)
          LastAsk.record(sid, state_dir: default_state_dir) unless ClientId.parent_line?(client_id)
          response
        end
      end

      # The inline create's folder: [dir, nil] or [nil, a 400 invalid_dir].
      # web.ask_dir (read now, StartDir's rules, from home) when the body
      # names none; unset, chi web's start folder.
      def ask_create_dir(body)
        dir, error = scope_dir(body["dir"])
        return [nil, error] if error
        return [dir, nil] if dir

        configured = Config.get("web.ask_dir")
        return [start_dir, nil] if configured.to_s.strip.empty?

        [StartDir.resolve(configured, from: :ask_config), nil]
      rescue StartDir::Invalid => e
        [nil, error_response(400, "invalid_dir", e.message)]
      end

      # The idle spawn, prompt as its preview: [session, nil]; [nil, nil]
      # when +session_id+ (a request_id's) is a session already (a retry:
      # nothing spawns); [nil, a 400 invalid_model].
      def ask_create_spawn(body, prompt, folder, session_id)
        return [nil, nil] if session_id && Session.exist?(session_id, state_dir: default_state_dir)

        ids = session_id ? { session_id: session_id } : {}
        session = @manager.spawn_session(prompt: nil, preview: prompt.strip, client_id: body["client_id"] || ClientId::WEB_CREATE,
                                         state_dir: @state_dir, **folder, **ids)
        [session, nil]
      rescue ModelProfile::MissingModel => e
        [nil, error_response(400, "invalid_model", e.message)]
      rescue SessionManager::IdTaken
        [nil, nil]
      end

      # The Ask on the new (or retried) session, its answer a 201 with
      # +extra+ (a refusal keeps its code). Not a :session route: a session
      # deleted meanwhile is 404 here, and a one-turn chi run's 409 too.
      def ask_create_run(sid, prompt, client_id, options, reply_for, deadline, body, extra)
        outcome = run_ask(sid, prompt: prompt, client_id: client_id, options: options, deadline: deadline, body: body)
        response = ask_response(sid, outcome, request_id: options[:request_id], reply_for: reply_for)
        with_fields(response, status: (201 if response.first == 200), **extra)
      rescue SessionManager::OwnedByTUI => e
        with_fields(owned_by_tui(e), **extra)
      rescue ArgumentError => e
        with_fields(error_response(404, "not_found", e.message), **extra)
      end
    end
  end
end
