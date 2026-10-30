# frozen_string_literal: true

require_relative "../client_id"
require_relative "../guardrails/parent_policy"
require_relative "../llm_context_override"
require_relative "../model_profile"
require_relative "../parent_answers_command"
require_relative "../prompt_history"
require_relative "../review_start"
require_relative "../send_command"
require_relative "../session"
require_relative "../session_access"
require_relative "../session_chain"
require_relative "../session_config"
require_relative "../session_continue"
require_relative "../session_manager"
require_relative "../session_setup"
require_relative "../thinking"
require_relative "../toolkit"
require_relative "../turn_flow"

module Samagotchi
  module Web
    # POST /api/sessions: a new session (handle_create), a continue
    # (handle_continue, continue_from), a review fork (request_review,
    # handle_review_fork), and their refusals (continue_refusal,
    # create_refusal, parent_gate, vision_refused) and request readers
    # (request_toolkit, request_parent_answers, request_llm_context,
    # request_thinking). Included in App: its ROUTES name handle_create, and
    # its helpers (json_response, error_response, parse_json, request_body,
    # await_worker_link, session_to_json, record_history, scope_dir, …) and
    # ivars (@manager, @session_class, @state_dir, @hub) answer. See
    # docs/architecture.md (chi web's routes).
    module SessionCreate
      # What a review session's create refuses beside review.
      REVIEW_REFUSES = %w[prompt preview idle continues].freeze

      # What a continue takes from the previous link: refused beside it.
      CONTINUE_TAKES = %w[dir llm_context thinking settings toolkit tools no_tools parent_answers].freeze

      # chi send's client ids: its lines are checked as chi send checks them
      # (#parent_gate).
      CLI_SEND_IDS = [ClientId::CLI_SEND, ClientId::CLI_ANSWER].freeze

      private

      def handle_create(req)
        body = parse_json(request_body(req))
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end

        prompt = body["prompt"] || body[:prompt]
        # idle: a session with no first turn, for a first message with
        # images (the page uploads them into it, then sends the turn).
        idle = body["idle"] == true
        review, error = request_review(body)
        return error if error
        return handle_review_fork(body, review) if review&.from

        if prompt.to_s.strip.empty? && !idle && !review
          return error_response(400, "missing_fields", "prompt is required")
        end
        return handle_continue(body, prompt, idle) if body.key?("continues")

        # dir: the folder the chat starts in (the page's scope); without it,
        # the folder chi web starts in (StartDir).
        dir, error = scope_dir(body["dir"])
        return error if error

        # llm_context: the session's own LLM context values before its first
        # turn (the start page's ⚙ panel; chi --llm-context), read
        # before anything spawns so a bad one spawns nothing.
        llm_context, error = request_llm_context(body["llm_context"])
        return error if error

        # thinking: the session's own thinking level (the start page's think
        # chip; chi --thinking), checked the same way.
        thinking, error = request_thinking(body["thinking"])
        return error if error

        # settings: the session's own settings, flat as chi --set names
        # them ({"recap.enabled" => false, "cost-cap.cap" => 3}), checked
        # the same way (SessionConfig.from_request).
        begin
          settings = SessionConfig.from_request(body["settings"])
        rescue SessionConfig::Error => e
          return error_response(400, "invalid_settings", e.message)
        end

        # toolkit, tools, no_tools: its toolkit (chi send --new --toolkit,
        # --tool, --no-tool: a name, tool names added and left out);
        # parent_answers: what a parent agent may answer on its questions
        # (hard, standard or soft; a looser one than config.yml's is capped,
        # and the 201's parent_answers_warning says so).
        toolkit, error = request_toolkit(body)
        return error if error

        parent_answers, error = request_parent_answers(body["parent_answers"])
        return error if error

        model = (body["model"] || body["model_name"]).to_s.strip
        refused = create_refusal(body, idle ? body["preview"] : prompt, values: [parent_answers], model: model)
        return refused if refused

        folder = { working_directory: dir || start_dir }
        # model: the model the session starts on (the start page's picker,
        # spelled as GET /api/models lists it); blank means the default.
        folder[:model_name] = model unless model.empty?
        # preview: an idle session's first message, sent as its first turn
        # next; the list and the notifications name the session by it
        # until that turn is saved.
        preview = idle ? body["preview"].to_s.strip : ""
        folder[:preview] = preview unless preview.empty?
        setup = SessionSetup.new(llm_context: llm_context, thinking: thinking, settings: settings, toolkit: toolkit,
                                 parent_answers: parent_answers)
        folder[:setup] = setup unless setup.empty?
        begin
          session = if review
                      ReviewStart.start(subjects: review.subjects, dir: dir || start_dir, model: folder[:model_name],
                                        setup: setup, state_dir: @state_dir)
                    else
                      @manager.spawn_session(prompt: idle ? nil : prompt.to_s, state_dir: @state_dir, **folder)
                    end
        rescue ModelProfile::MissingModel => e
          # No model configured, or one qualified with an unknown host.
          return error_response(400, "invalid_model", e.message)
        rescue ReviewStart::Refused => e
          return error_response(400, "invalid_review", e.message)
        end
        # The worker's Bridge is the single live transport: wait (bounded) for
        # it so the client can attach without client-side polling.
        port = await_worker_link(session.id).then { |link| link.live? ? link.port : nil }
        # The projection holds it before the page hears back (no tick wait).
        @hub&.touch(session.id)
        record_history(body, prompt) if !idle && PromptHistory.shell_line?(prompt.to_s.strip)
        json_response(201, session_to_json(session).merge(bridge_port: port, model_warning: session.model_warning,
                                                          parent_answers_warning: Guardrails::ParentPolicy.capped_note(parent_answers),
                                                          first_turn_id: session.first_turn_id))
      end

      # POST /api/sessions with continues: <id, prefix or last:id>: the next
      # link of that session's chain (SessionManager.continue_session), in its
      # folder and with its own setup (SessionSetup: llm_context, thinking
      # and reasoning_history levels, settings), so dir, llm_context, thinking and settings are
      # refused beside it (a create takes no reasoning_history). It runs on
      # model (or model_name) when given, else on the previous link's: one
      # whose host is gone falls back to the default, and the 201's
      # model_warning (null when none) says so. Its opener is the text the
      # page prefills (SessionChain.opener_for; null: the page's constant).
      # A model it can't start on is 400 invalid_model, nothing archived.
      # 409 continued (with next_id, the link that continues it already: the
      # page opens that one), open_children (ids), folder_gone, busy, scratch
      # or owned_by_tui.
      def handle_continue(body, prompt, idle)
        given = body["continues"]
        unless given.is_a?(String) && !given.strip.empty?
          return error_response(400, "invalid_continues", "continues is a session id")
        end
        if (fields = CONTINUE_TAKES.select { |key| body.key?(key) }).any?
          return error_response(400, "invalid_continues",
                                "continues takes the previous session's folder, llm_context, thinking, toolkit, " \
                                "settings and parent_answers; leave out #{fields.join(", ")}")
        end

        preview = idle ? body["preview"].to_s.strip : ""
        model = (body["model"] || body["model_name"]).to_s.strip
        refused = continue_refusal(given, body, idle ? body["preview"] : prompt, model: model)
        return refused if refused

        session, error = continue_from(given, prompt: idle ? nil : prompt.to_s, preview: preview.empty? ? nil : preview,
                                              model: model.empty? ? nil : model)
        return error if error

        port = await_worker_link(session.id).then { |link| link.live? ? link.port : nil }
        moved = session.moved_children || []
        # The moved delegates' cards fold under the new link now.
        [session.continues, session.id, *moved].each { |sid| @hub&.touch(sid) }
        record_history(body, prompt) if !idle && PromptHistory.shell_line?(prompt.to_s.strip)
        json_response(201, session_to_json(session).merge(bridge_port: port, moved: moved,
                                                          model_warning: session.model_warning,
                                                          opener: session.opener,
                                                          first_turn_id: session.first_turn_id))
      end

      # The create's review: {subjects: [paths], from: id} (chi review, the
      # page's Start review) as a SessionAccess::Review: [review, nil] (nil
      # when absent), or [nil, a 400 invalid_review]. A review session
      # starts idle: prompt, preview, idle and continues are refused beside
      # it. Its subjects are checked where it starts (ReviewStart).
      def request_review(body)
        return [nil, nil] unless body.key?("review")

        raw = body["review"]
        subjects = raw.is_a?(Hash) ? raw.fetch("subjects", []) : nil
        from = raw.is_a?(Hash) ? raw["from"] : nil
        unless subjects.is_a?(Array) && subjects.all?(String) && (from.nil? || (from.is_a?(String) && !from.strip.empty?))
          return [nil, error_response(400, "invalid_review", "review is {subjects: [project files], from: a session id}")]
        end
        if (fields = REVIEW_REFUSES.select { |key| body.key?(key) }).any?
          return [nil, error_response(400, "invalid_review", "a review session starts idle; leave out #{fields.join(", ")}")]
        end

        [SessionAccess::Review.new(subjects: subjects, from: from&.strip), nil]
      end

      # POST /api/sessions with review.from: a review fork of that session
      # (ReviewStart.fork), in its folder and with its setup (dir and the
      # setup fields refused beside it, as for a continue), on model when
      # given. 201 as a create's; 400 invalid_review (a subject, its folder
      # gone), invalid_model, ambiguous_id; 404 not_found.
      def handle_review_fork(body, review)
        if (fields = CONTINUE_TAKES.select { |key| body.key?(key) }).any?
          return error_response(400, "invalid_review",
                                "a review of a session takes its folder and setup; leave out #{fields.join(", ")}")
        end

        model = (body["model"] || body["model_name"]).to_s.strip
        begin
          session = ReviewStart.fork(from: review.from, subjects: review.subjects, model: model.empty? ? nil : model,
                                     state_dir: @state_dir)
        rescue ReviewStart::Refused => e
          return error_response(400, "invalid_review", e.message)
        rescue ModelProfile::MissingModel => e
          return error_response(400, "invalid_model", e.message)
        rescue Session::AmbiguousId => e
          return refusal_response(400, "ambiguous_id", e, ids: e.ids)
        rescue ArgumentError => e
          return error_response(404, "not_found", e.message)
        end
        port = await_worker_link(session.id).then { |link| link.live? ? link.port : nil }
        @hub&.touch(session.id)
        json_response(201, session_to_json(session).merge(bridge_port: port, model_warning: session.model_warning))
      end

      # The previous link's parent_answers and the model the new one runs,
      # for #create_refusal; nil when the previous link isn't there
      # (continue_from says so).
      def continue_refusal(given, body, line, model:)
        return nil unless body["check_vision"] == true || CLI_SEND_IDS.include?(body["client_id"])

        previous = Session.load(SessionChain.resolve(given, state_dir: default_state_dir), state_dir: default_state_dir)
        create_refusal(body, line, values: [previous.parent_answers], model: model, previous: previous)
      rescue ArgumentError, ModelProfile::MissingModel
        nil
      end

      # A create refused before anything spawns, as chi send --new refuses
      # it (SendCommand::ParentGate, the vision check): its first line
      # (+line+, the prompt or an idle one's preview) when it is a parent
      # agent's /continue yes or a /parent-answers that loosens +values+
      # (#parent_gate), and with check_vision: true (its first message
      # brings images) a model known not to take them (422 no_vision).
      # @param previous [Session, nil] a continue's previous link: its model
      #   decides when +model+ is blank
      # @return [Array, nil] the response, or nil to go on
      def create_refusal(body, line, values:, model:, previous: nil)
        refused = parent_gate(line, client_id: body["client_id"], values: values)
        return refused if refused
        return nil unless body["check_vision"] == true

        name, typed = if previous
                        SendCommand.continued_model(previous, model)
                      else
                        [model.empty? ? nil : model, nil]
                      end
        vision_refused(name, typed)
      end

      # A line from chi send (client_id cli:send, or cli:answer for a parent
      # agent's /continue yes) refused here as chi send refuses it on its own
      # machine (SendCommand::ParentGate), held to this server's config.yml:
      # a parent's /continue yes that guardrails.parent_answers (tightened by
      # +values+, the targets' own parent_answers) refuses, 403
      # parent_continue_refused; a /parent-answers line that loosens one of
      # +values+, 403 parent_answers_refused (loosening is the user's at a
      # UI). The page's lines (web:…) and others aren't checked here; the
      # worker checks every line again.
      # @return [Array, nil] the response, or nil to go on
      def parent_gate(line, client_id:, values:)
        line = line.to_s
        return nil unless CLI_SEND_IDS.include?(client_id)

        if client_id == ClientId::CLI_ANSWER && TurnFlow.continue_yes?(line) &&
           (refusal = SendCommand::ParentGate.continue_refusal_for(values))
          return error_response(403, "parent_continue_refused", refusal)
        end
        return nil unless SendCommand::ParentGate.loosens_any?(line, values)

        error_response(403, "parent_answers_refused", ParentAnswersCommand::REFUSED)
      end

      # 422 no_vision in chi send's words when the model (+name+, nil: the
      # default) is known not to take images; nil when it does or is
      # unknown (the worker decides when the turn runs).
      def vision_refused(name, typed)
        refusal = SendCommand.vision_refusal(name, SendCommand.vision_answer(name, typed: typed))
        refusal && error_response(422, "no_vision", refusal)
      end

      # The create request's toolkit (a name), tools and no_tools (names, a
      # comma list each too), as chi send --new's --toolkit, --tool and
      # --no-tool: [toolkit, nil] (nil for none), or [nil, a 400 response].
      def request_toolkit(body)
        name = body["toolkit"]
        lists = %w[tools no_tools].to_h { |key| [key, body[key]] }
        unless (name.nil? || name.is_a?(String)) &&
               lists.values.all? { |list| list.nil? || (list.is_a?(Array) && list.all?(String)) }
          return [nil, error_response(400, "invalid_toolkit", "toolkit is a name; tools and no_tools are lists of names")]
        end

        [Toolkit.from_flags(name: name, add: lists["tools"] || [], remove: lists["no_tools"] || []), nil]
      end

      # The create request's parent_answers (hard, standard or soft;
      # "default" or none: config.yml's): [level, nil] or [nil, a 400].
      def request_parent_answers(raw)
        return [nil, nil] if raw.nil?

        level = raw.is_a?(String) ? Guardrails::ParentPolicy.parse_level(raw) : :invalid
        return [nil, nil] if level == :unset
        unless Guardrails::ParentPolicy::ORDER.include?(level)
          return [nil, error_response(400, "invalid_parent_answers",
                                      "parent_answers takes #{Guardrails::ParentPolicy::ORDER.join(", ")}")]
        end

        [level, nil]
      end

      # SessionManager.continue_session, its refusals as responses: [session,
      # nil] or [nil, the response]. Only its own errors: what fails after
      # the new link started is not a refusal of it.
      def continue_from(given, prompt:, preview:, model:)
        [@manager.continue_session(given, prompt: prompt, preview: preview, model: model, state_dir: @state_dir), nil]
      rescue SessionContinue::Refused => e
        extra = e.reason == :continued ? { next_id: e.ids.first } : {}
        [nil, refusal_response(409, e.reason.to_s, e, session_id: e.session_id, reason: e.reason.to_s, ids: e.ids, **extra)]
      rescue SessionManager::ArchiveRefused => e
        [nil, archive_refused(e)]
      rescue SessionManager::OwnedByTUI => e
        [nil, owned_by_repl(given, e)]
      rescue ModelProfile::MissingModel => e
        [nil, error_response(400, "invalid_model", e.message)]
      rescue Session::AmbiguousId => e
        [nil, refusal_response(400, "ambiguous_id", e, ids: e.ids)]
      rescue ArgumentError => e
        [nil, error_response(404, "not_found", e.message)]
      end

      # The create request's "llm_context" ({strategy:, apply:, budget:},
      # each a word as /llm-context takes it, "default" for unset) as an
      # override: [override, nil] (nil when absent or all default), or
      # [nil, a 400 response] for anything else.
      def request_llm_context(raw)
        return [nil, nil] if raw.nil?

        fields = LLMContextOverride::COMMAND_WORDS.invert
        unless raw.is_a?(Hash) && raw.all? { |key, word| fields.key?(key) && word.is_a?(String) }
          return [nil, error_response(400, "invalid_llm_context",
                                      "llm_context is an object of #{fields.keys.join(", ")} words")]
        end

        override = LLMContextOverride.update(nil, raw.to_h { |key, word| [fields.fetch(key), word] })
        [override.empty? ? nil : override, nil]
      rescue ArgumentError => e
        [nil, error_response(400, "invalid_llm_context", e.message)]
      end

      # The create request's "thinking" (a level word as /thinking takes it,
      # "default" for none) as the session's own level: [level, nil] (nil
      # when absent or default), or [nil, a 400 response] for anything else.
      def request_thinking(raw)
        return [nil, nil] if raw.nil?

        word = raw.is_a?(String) ? raw.strip.downcase : nil
        unless word && Thinking::LEVELS.map(&:to_s).include?(word)
          return [nil, error_response(400, "invalid_thinking", "thinking is one of #{Thinking::LEVELS.join(", ")}")]
        end

        [Thinking.session_level(word), nil]
      end
    end
  end
end
