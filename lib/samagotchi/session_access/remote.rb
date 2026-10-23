# frozen_string_literal: true

require_relative "../session"
require_relative "../session_access"
require_relative "../remotes"
require_relative "../reply_wait"
require_relative "../pending_question"
require_relative "../note_delivery"
require_relative "../owner_lock"
require_relative "../context_sources"
require_relative "../bridge_client"
require_relative "../session_continue"
require_relative "../guardrails/parent_policy"
require_relative "../model_profile"
require_relative "http_transport"
require_relative "../chi_invocation"

module Samagotchi
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module SessionAccess
    # Another machine's sessions, through its chi web (the remote-sessions
    # plan): SessionAccess::Local's methods, each a request to the route of
    # the same name (Web::SessionAccessRoutes and the page's own), with the
    # remote's token as Authorization: Bearer. Results are Local's value
    # objects (SessionView and Created where Local hands out a Session), and
    # a refusal raises the exception Local's callee raises, built from the
    # fields chi web sends (its message is the same). A request that can't
    # be made, or a chi web without these routes, raises RemoteFailed naming
    # the remote. Waits and prefixes run on the server (plan D2); a wait
    # here asks again until it ends or the caller's own timeout passes.
    class Remote
      # The longest a wait route waits (Web::SessionAccessRoutes::
      # WAIT_MAX_SECONDS): each request asks for at most this.
      WAIT_SLICE = 30.0
      # chi web stopping mid-wait (503 server_stopping): asked again after
      # this, until the caller's own timeout.
      RETRY_AFTER = 1.0

      attr_reader :entry

      # @param entry [Remotes::Entry]
      # @param transport [#call] HTTPTransport by default; specs pass one
      #   that calls the Rack app in this process
      # @param clock [#call] the monotonic seconds a wait's deadline is
      #   counted on (specs pass their own)
      def initialize(entry, transport: nil, sleeper: ->(seconds) { sleep(seconds) },
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @entry = entry
        @transport = transport || HTTPTransport.new(entry)
        @sleeper = sleeper
        @clock = clock
        @strategies = {}
      end

      def inspect = "#<#{self.class.name} #{@entry.label}>"

      def remote? = true
      def name = @entry.name

      # The printed commands' spelling: chi --remote NAME.
      # @return [ChiInvocation]
      def invocation = ChiInvocation.new(remote: name)

      # Web::SessionAccessRoutes::FEATURE (GET /api/info's), without
      # loading chi web here.
      FEATURE = "session_commands"
      # Web::SessionAccessRoutes::ATTACH_FEATURE: the routes a remote
      # attached TUI needs (wake, worker).
      ATTACH_FEATURE = "remote_attach"

      # What GET /api/info's +reply+ says is wrong with +entry+'s chi web for
      # chi --remote, as the error to raise; nil when it will do (chi remote
      # add checks the same).
      # @return [RemoteFailed, nil]
      def self.info_problem(entry, reply)
        failure = auth_failure(entry, reply)
        return AuthRefused.new(failure) if failure
        unless reply.status == 200 && reply.json.is_a?(Hash) && reply.json["app"] == "chi-web"
          return RemoteFailed.new("#{entry.label}: not chi web (GET /api/info answered #{reply.status})")
        end
        return nil if Array(reply.json["features"]).include?(FEATURE)

        RemoteTooOld.new(too_old_message(entry, reply.json["version"]))
      end

      # By feature, not by a release number (that is the release's to
      # name): a chi without the routes, or without the one a command asks.
      def self.too_old_message(entry, version)
        "remote #{entry.name} runs chi #{version || "(unknown)"}, too old for this command through --remote: " \
          "update chi there (chi update)"
      end

      # The words for a 401 or a 403 forbidden from +entry+'s chi web, nil
      # for any other answer (chi remote add says the same).
      def self.auth_failure(entry, reply)
        case reply.status
        when 401 then "#{entry.label}: the token was refused (chi web's LAN link carries the current one: " \
                      "chi remote add #{entry.name} #{entry.url} --token-file FILE)"
        when 403
          return nil unless reply.error == "forbidden"

          ip = reply.json["detail"].to_s[/ and (\S+) are answered/, 1]
          "#{entry.label}: chi web answers its LAN IP only: use the LAN IP#{" #{ip}" if ip}, not a hostname"
        end
      end

      # --- ids and sessions

      # @raise [Session::AmbiguousId]
      def resolve_id(given)
        reply = request(:get, "/api/sessions/resolve", query: { id: given.to_s })
        case reply.status
        when 200 then reply.json.fetch("id")
        when 404 then given.to_s
        else raise_refusal(reply)
        end
      end

      # @raise [ArgumentError] no such session (Session::AmbiguousId: a
      #   prefix of several)
      def resolve(given)
        id = resolve_id(given)
        raise ArgumentError, "Session not found: #{given}" if id == given.to_s && !exists?(id)

        id
      end

      # @return [SessionView]
      # @raise [ArgumentError] no such session
      def show(id)
        reply = request(:get, session_path(id), query: { brief: 1 })
        raise_refusal(reply) unless reply.status == 200

        view_of(reply.json["session"] || {}, reply.json["pending_question"])
      end

      # @return [OwnerLock::Owner, nil]
      def owner(id) = show(id).owner

      # The rows chi sessions list prints, as SessionManager.session_summaries
      # gives them (symbol keys).
      def summaries(live: false, cwd: nil, limit: nil, include_tests: true, project_root: nil, include_archived: false,
                    sort: nil, order: nil)
        query = { live: (1 if live), cwd: cwd, limit: limit, tests: (0 unless include_tests), dir: project_root,
                  archived: (1 if include_archived), sort: sort, order: order }
        reply = request(:get, "/api/sessions/summaries", query: query)
        raise_refusal(reply) unless reply.status == 200

        Array(reply.json).map { |row| symbolize(row) }
      end

      # --- create and send

      # @param spec [NewSession] its setup a SetupWords
      # @return [Created]
      def create(spec)
        reply = request(:post, "/api/sessions", body: create_body(spec))
        raise_refusal(reply) unless reply.status == 201

        json = reply.json
        Created.new(id: json.fetch("id"), model_warning: json["model_warning"], continues: json["continues"],
                    moved_children: json["moved"] || [], parent_answers_warning: json["parent_answers_warning"])
      end

      # Whether a just-created session's worker came up within +timeout+
      # seconds: its owner lock, as the brief read names it (chi web's
      # create waited for its Bridge a bounded time already).
      def await_worker(id, timeout:)
        deadline = monotonic + timeout
        loop do
          return true if owner(id)&.worker?
          return false if monotonic >= deadline

          sleep(WORKER_POLL)
        end
      end

      WORKER_POLL = 0.1

      # Each image (an ImageStore ref stored in +from+) uploaded into the
      # session (POST …/images), as the refs a turn takes.
      def upload_images(id, refs, from:)
        refs.map do |ref|
          file = (ref[:file] || ref["file"]).to_s
          name = (ref[:name] || ref["name"]).to_s
          reply = request(:post, "#{session_path(id)}/images", query: { name: name },
                                                               raw: File.binread(File.join(from.to_s, file)))
          raise_refusal(reply) unless reply.status == 201

          { file: reply.json.fetch("file"), name: reply.json["name"] || name }
        end
      end

      # @return [SessionManager::DeliverResult]
      # @raise [SessionManager::OwnedByTUI]
      def deliver_turn(id, prompt:, client_id:, images:, delivery: nil)
        body = { prompt: prompt, client_id: client_id, history: false }
        body[:images] = images.map { |ref| { file: ref[:file], name: ref[:name] } } unless images.empty?
        body[:check_vision] = true unless images.empty?
        body[:delivery] = delivery if delivery
        reply = request(:post, "#{session_path(id)}/turn", body: body)
        ack = reply.json.is_a?(Hash) ? reply.json : {}
        case reply.status
        when 202
          via = ack["via"] == "file" ? :file : :bridge
          SessionManager::DeliverResult.new(status: :accepted, via: via, ack: ack.except("via"))
        when 504 then SessionManager::DeliverResult.new(status: :timeout, ack: { "detail" => ack["detail"] })
        when 409
          raise SessionManager::OwnedByTUI, ack["session_id"] || id if ack["error"] == "owned_by_tui"

          SessionManager::DeliverResult.new(status: :refused, code: 409, ack: ack)
        when 404 then raise_refusal(reply)
        else
          return SessionManager::DeliverResult.new(status: :refused, code: reply.status, ack: ack) if (400..499).cover?(reply.status)

          SessionManager::DeliverResult.new(status: :failed, ack: ack)
        end
      end

      # @return [NoteDelivery::Result]
      # @raise [SessionInbox::NoteRejected]
      def note(id, text:, source:)
        reply = request(:post, "#{session_path(id)}/notes", body: { text: text, source: source })
        json = reply.json.is_a?(Hash) ? reply.json : {}
        case reply.status
        when 200 then NoteDelivery::Result.new(id: id, status: json["status"].to_sym, queued: json["queued"].to_i)
        when 409
          return NoteDelivery::Result.new(id: id, status: :refused, queued: 0) if json["error"] == "owned_by_tui"

          raise_refusal(reply)
        when 400
          raise SessionInbox::NoteRejected, json["detail"].to_s if json["error"] == "note_rejected"

          raise_refusal(reply)
        else raise_refusal(reply)
        end
      end

      # --- waiting for the reply

      # The pre-send state, read on the server (POST …/wait/prepare).
      # +session+ is the caller's read, unused here: the server reads its
      # own.
      # @return [WaitStart]
      def prepare_wait(id, session: nil, question_id: :pending, turn: nil, created: false)
        _ = session
        body = { turn: turn, created: created }
        body[:question_id] = question_id unless question_id == :pending
        reply = request(:post, "#{session_path(id)}/wait/prepare", body: body)
        raise_refusal(reply) unless reply.status == 200

        wait_start_of(reply.json)
      end

      # chi send --wait's busy check, on the server (the wait prepare
      # route's busy: true).
      # @return [SendCommand::Busy, nil]
      def busy(id, queue:, session: nil)
        _ = session
        reply = request(:post, "#{session_path(id)}/wait/prepare", body: { busy: true, queue: queue })
        return nil if reply.status == 200

        raise_refusal(reply) unless reply.status == 409 && %w[busy waiting].include?(reply.error)

        require_relative "../send_command/busy"
        SendCommand::Busy.new(error: reply.error, session_id: reply.json["session_id"] || id,
                              question: PendingQuestion.from_file(reply.json["question"]),
                              strategy: strategy_of(reply.json["parent_strategy"]))
      end

      # ReplyWait on the server, asked again each WAIT_SLICE until it ends
      # or +timeout+ passes.
      # @return [ReplyWait::Result]
      # @raise [ArgumentError] the session is gone
      def wait_reply(id, cursor:, timeout:, baseline:, owner_grace: nil, turn: nil, queued: false, ended_before: false,
                     poll_interval: nil)
        _ = poll_interval
        deadline = timeout && (monotonic + timeout)
        body = { cursor: cursor, baseline: baseline&.to_h, turn: turn, queued: queued, ended_before: ended_before,
                 owner_grace: owner_grace }
        loop do
          left = deadline && (deadline - monotonic)
          return ReplyWait::Result.new(status: :timeout) if left && left <= 0

          reply = request(:post, "#{session_path(id)}/wait", body: body.merge(timeout: [left || WAIT_SLICE, WAIT_SLICE].min))
          if reply.status == 503 && reply.error == "server_stopping"
            @sleeper.call(RETRY_AFTER)
            next
          end
          raise_refusal(reply) unless reply.status == 200

          @strategies[id] = strategy_of(reply.json["parent_strategy"])
          result = result_of(reply.json)
          return result unless result.status == :timeout
        end
      end

      # What a parent may pick on the session's questions: the server's
      # (its config.yml tightened by the session's own), as its last wait
      # said, else the strictest.
      def parent_strategy(id) = @strategies[id] || Guardrails::ParentPolicy.strategy(Guardrails::ParentPolicy::HARD)

      # --- questions

      # The answer, through chi web to the session's worker. chi web's
      # answers mapped back to the Bridge's own (AnswerCommand reads those).
      # @return [BridgeClient::Response, nil] nil when no worker runs it
      def answer(id, question_id:, selected:, freeform:, client_id:)
        bridge_reply(request(:post, "#{session_path(id)}/answer",
                             body: { id: question_id, selected: selected, freeform: freeform, client_id: client_id }))
      end

      def dismiss(id, question_id:)
        bridge_reply(request(:post, "#{session_path(id)}/question/dismiss", body: { id: question_id }))
      end

      # --- sessions

      # chi web stops it and waits its own bounded time (Web::App::
      # STOP_WAIT_SECONDS, not +wait+).
      # @return [Boolean] whether the worker had released it by then, as
      #   chi web's released says (absent: true)
      def stop(id, wait:)
        _ = wait
        reply = request(:post, "#{session_path(id)}/stop")
        raise_refusal(reply) unless reply.status == 200

        reply.json["released"] != false
      end

      # @return [SessionManager::Restarted]
      def restart(id)
        reply = request(:post, "#{session_path(id)}/restart")
        raise_refusal(reply) unless reply.status == 200

        SessionManager::Restarted.new(session_id: reply.json["session_id"] || id, from_version: reply.json["from_version"],
                                      version: reply.json["version"])
      end

      # @return [Hash] {id:, archived:, stopped:, discarded:}
      def archive(id)
        reply = request(:post, "#{session_path(id)}/archive")
        raise_refusal(reply) unless reply.status == 200

        { id: reply.json["session_id"] || id, archived: Array(reply.json["archived"]), stopped: Array(reply.json["stopped"]),
          discarded: Array(reply.json["discarded"]) }
      end

      # @return [Hash] {id:, unarchived:}
      def unarchive(id)
        reply = request(:post, "#{session_path(id)}/unarchive")
        raise_refusal(reply) unless reply.status == 200

        { id: reply.json["session_id"] || id, unarchived: Array(reply.json["unarchived"]) }
      end

      # @return [Hash] {id:, stopped:}
      def delete(id, force:)
        reply = request(:delete, session_path(id), query: { force: (true if force) })
        raise_refusal(reply) unless reply.status == 200

        { id: reply.json["session_id"] || id, stopped: reply.json["stopped"] == true }
      end

      # --- context (a session's own sources: a project's are local only)

      # @raise [ContextSources::Invalid] refused (a name taken, a bad one)
      def context_add(target, source)
        body = { name: source.name, why: source.why, hint: source.hint, added_by: source.added_by }
        source.push? ? body[:push] = true : body.merge!(cmd: source.cmd, every: source.every_seconds)
        context_added(request(:post, "#{session_path(target.session_id)}/context", body: body.compact))
        nil
      end

      # A URL through the remote's installed bundles' providers (chi web's
      # {url} body: the page's own).
      # @return [String] the source's name
      # @raise [ContextProviders::Invalid] no bundle there resolves it
      def context_add_url(target, url, why:, hint:, added_by:)
        reply = request(:post, "#{session_path(target.session_id)}/context",
                        body: { url: url, why: why, hint: hint, added_by: added_by }.compact)
        if reply.status == 422
          require_relative "../context_providers"
          detail = if reply.error == "no_provider" && reply.json["detail"].to_s.start_with?("no installed bundle resolves")
                     "no installed bundle on #{name} resolves #{url} (chi bundle install github-pr there for GitHub PRs)"
                   else
                     "#{reply.json["detail"]} (on #{name})"
                   end
          raise ContextProviders::Invalid, detail
        end
        context_added(reply)
        reply.json.fetch("name")
      end

      # @param fetched [ContextSources::Fetched]
      # @return [ContextPush]
      def context_push(target, name, fetched)
        reply = request(:post, "#{session_path(target.session_id)}/context/#{name}/push",
                        body: { text: fetched.text, summary: fetched.summary, wake: fetched.wake, hint: fetched.hint })
        case reply.status
        when 200 then ContextPush.new(status: :pushed, before: reply.json["before"], revision: reply.json["revision"])
        when 404
          return ContextPush.new(status: :missing) if reply.error == "not_found"

          raise_refusal(reply)
        when 409 then ContextPush.new(status: :not_push)
        when 400 then raise ContextSources::Invalid, reply.json["detail"].to_s
        else raise_refusal(reply)
        end
      end

      # @return [Array<ContextEntry>]
      def context_entries(target)
        reply = request(:get, "#{session_path(target.session_id)}/context", query: { full: 1 })
        raise_refusal(reply) unless reply.status == 200

        Array(reply.json["sources"]).map { |row| context_entry_of(row) }
      end

      # @return [ContextEntry, nil]
      def context_entry(target, name)
        ContextSources.check_name!(name)
        reply = request(:get, "#{session_path(target.session_id)}/context/#{name}", query: { full: 1 })
        return nil if reply.status == 404 && reply.error == "not_found" && reply.json["detail"].to_s.start_with?("no source")

        raise_refusal(reply) unless reply.status == 200

        context_entry_of(reply.json, text: reply.json["text"])
      end

      # @return [Symbol] :removed, :project or :missing
      def context_remove(target, name)
        ContextSources.check_name!(name)
        reply = request(:delete, "#{session_path(target.session_id)}/context/#{name}", query: { own: 1 })
        case reply.status
        when 200 then :removed
        when 409 then reply.error == "project_source" ? :project : raise_refusal(reply)
        when 404 then reply.json["detail"].to_s.start_with?("no source") ? :missing : raise_refusal(reply)
        else raise_refusal(reply)
        end
      end

      # --- a remote attach

      # The client a remote attached TUI talks to the session's worker
      # with, through this chi web.
      # @param worker [Hash] the live worker as POST …/wake or GET …/worker
      #   gave it: its epoch is its key (started_at for a worker from before
      #   the epoch in its sidecar)
      # @return [WebBridgeClient]
      def attach_client(id, worker:)
        require_relative "web_bridge_client"
        WebBridgeClient.new(remote: self, session_id: id, worker_key: worker["epoch"] || worker["started_at"])
      end

      # This chi web has +feature+ (GET /api/info's), else RemoteTooOld in
      # Remote.too_old_message's words.
      # @raise [RemoteFailed]
      def require_feature!(feature)
        check_server!
        raise RemoteTooOld, too_old(@version) unless Array(@features).include?(feature)
      end

      # POST …/wake: the session's live worker for a remote attach, started
      # when none runs, waited for up to +wait+ seconds there.
      # @return [WakeReply]
      # @raise [SessionManager::OwnedByTUI] a chi REPL has it there
      # @raise [Refused] a leftover scratch session (code scratch), or its
      #   Bridge didn't come in time (code worker_timeout): chi web's words,
      #   LaunchMode's constants
      # @raise [ArgumentError] no such session
      def attach_wake(id, wait:)
        reply = request(:post, "#{session_path(id)}/wake", body: { wait: wait })
        if reply.status != 200 && %w[scratch worker_timeout].include?(reply.error)
          raise Refused.new((reply.json["message"] || reply.json["detail"]).to_s, code: reply.error)
        end

        raise_refusal(reply) unless reply.status == 200

        json = reply.json
        WakeReply.new(woke: json["woke"] == true, worker: json["worker"], default_model: json["default_model"],
                      strategy: strategy_or_hard(json["parent_strategy"]), installed: json["installed"])
      end

      # GET …/worker: the session's worker now (never started).
      # @return [WorkerReply]
      # @raise [ArgumentError] no such session
      def attach_worker(id)
        reply = request(:get, "#{session_path(id)}/worker")
        raise_refusal(reply) unless reply.status == 200

        json = reply.json
        WorkerReply.new(live: json["live"] == true, stopped: json["stopped"] == true, worker: json["worker"],
                        strategy: strategy_or_hard(json["parent_strategy"]))
      end

      # One request to a route, as the session commands make them (the
      # server check first; a refused token or a missing route raise
      # RemoteFailed): WebBridgeClient's, which maps the reply itself.
      # @return [HTTPTransport::Reply]
      # @raise [RemoteFailed]
      def route_request(method, path, **) = request(method, path, **)

      private

      def session_path(id) = "/api/sessions/#{id}"
      def monotonic = @clock.call

      def exists?(id)
        request(:get, session_path(id), query: { brief: 1 }).status == 200
      end

      # One request, after the first one's check that this chi web has the
      # routes (GET /api/info). A 401, a 403 forbidden, and a 404 for a
      # route it doesn't have (an older chi web) raise RemoteFailed here.
      def request(method, path, **)
        check_server!
        reply = @transport.call(method, path, **)
        raise AuthRefused, Remote.auth_failure(@entry, reply) if Remote.auth_failure(@entry, reply)
        raise RemoteTooOld, too_old(@version) if missing_route?(reply)

        reply
      end

      def check_server!
        return if @checked

        reply = @transport.call(:get, "/api/info")
        if reply.json.is_a?(Hash)
          @version = reply.json["version"]
          @features = Array(reply.json["features"])
        end
        problem = Remote.info_problem(@entry, reply)
        raise problem if problem

        @checked = true
      end

      def too_old(version) = Remote.too_old_message(@entry, version)

      def strategy_or_hard(json) = strategy_of(json) || Guardrails::ParentPolicy.strategy(Guardrails::ParentPolicy::HARD)

      # chi web's 404 for a path no route takes (#serve_static's), not a
      # route's own "no such session".
      def missing_route?(reply)
        reply.status == 404 && reply.error == "not_found" && reply.json["detail"].to_s.start_with?("not found: /")
      end

      # Raises what Local's callee raises for this refusal (chi web sends
      # the fields each class is built from; see docs/architecture.md, chi
      # web's routes for the session commands), else RemoteFailed.
      def raise_refusal(reply)
        json = reply.json.is_a?(Hash) ? reply.json : {}
        error = json["error"].to_s
        message = json["message"] || json["detail"]
        sid = json["session_id"]
        reason = json["reason"]&.to_sym
        case error
        when "not_found" then raise ArgumentError, message.to_s
        when "ambiguous_id" then raise Session::AmbiguousId.new(message, ids: Array(json["ids"]))
        when "owned_by_tui" then raise SessionManager::OwnedByTUI, sid
        when "worker_running", "still_stopping" then raise SessionManager::DeleteRefused.new(sid, reason)
        when "busy", "scratch"
          raise SessionManager::ArchiveRefused.new(sid, reason, busy_id: json["busy_id"]) if reason
        when "continued", "open_children", "folder_gone"
          raise SessionContinue::Refused.new(sid, reason, ids: Array(json["ids"]))
        when "held", "not_running", "unsupported", "failed"
          raise SessionManager::RestartRefused.new(sid, reason, version: json["version"]) if reason
        when "parent_answers_refused", "parent_continue_refused", "no_vision"
          raise Refused.new(message.to_s, code: error)
        # No model configured there, or --model's host unknown there: what
        # spawn_session raises here (chi send: could not start a session).
        when "invalid_model" then raise ModelProfile::MissingModel, message.to_s
        when /\Ainvalid_/, "missing_fields", "bad_images"
          raise BadRequest.new(message.to_s, code: error)
        end
        raise RemoteFailed, "#{@entry.label} answered #{reply.status}#{" #{error}" unless error.empty?}" \
                            "#{": #{message}" if message}"
      end

      def create_body(spec)
        body = { model: spec.model_name, client_id: spec.client_id, history: false }
        if spec.preview || spec.idle
          body.merge!(idle: true, preview: spec.preview)
        else
          body[:prompt] = spec.prompt
        end
        body[:check_vision] = true if spec.images
        if spec.continues
          body[:continues] = spec.continues
        else
          body[:dir] = spec.working_directory
          body.merge!(setup_body(spec.setup)) if spec.setup
        end
        body.compact
      end

      def setup_body(words)
        llm = words.llm_context&.to_h { |field, word| [LLM_CONTEXT_KEYS.fetch(field), word] }
        { llm_context: llm, thinking: words.thinking, toolkit: words.toolkit,
          tools: (words.tools unless Array(words.tools).empty?), no_tools: (words.no_tools unless Array(words.no_tools).empty?),
          settings: words.settings, parent_answers: words.parent_answers }.compact
      end

      # SetupWords' llm_context fields as the create route names them
      # (LLMContextOverride::COMMAND_WORDS).
      LLM_CONTEXT_KEYS = { strategy: "strategy", apply: "apply", budget_tokens: "budget" }.freeze
      private_constant :LLM_CONTEXT_KEYS

      def view_of(json, pending)
        owner = json["owner"] && OwnerLock::Owner.new(pid: nil, kind: json["owner"].to_s, started_at: nil)
        SessionView.new(id: json["id"], status: json["status"], title: json["title"],
                        display_title: json["display_title"] || json["title"] || json["first_preview"].to_s,
                        project_root: json["project_root"], working_directory: json["working_directory"],
                        model_name: json["model_name"], model_typed: json["model_typed"],
                        parent_answers: json["parent_answers"], owner: owner,
                        pending_question: PendingQuestion.from_file(pending))
      end

      def wait_start_of(json)
        baseline = ReplyWait::Baseline.new(**(json["baseline"] || {}).transform_keys(&:to_sym))
        WaitStart.new(cursor: json["cursor"], baseline: baseline, own_turn: json["own_turn"], known_turn: json["known_turn"],
                      running: json["running"] == true, live: json["live"] == true, settled: json["settled"] == true,
                      last_turn_id: json["last_turn_id"])
      end

      RESULT_FIELDS = %i[text file outcome limit error_kind retryable cancel_reason stopped_by kept_steps turn_id origin].freeze
      private_constant :RESULT_FIELDS

      def result_of(json)
        fields = RESULT_FIELDS.to_h { |key| [key, json[key.to_s]] }
        ReplyWait::Result.new(status: json["status"].to_s.to_sym, question: PendingQuestion.from_file(json["question"]),
                              **fields)
      end

      def strategy_of(json)
        return nil unless json.is_a?(Hash) && json["name"]

        Guardrails::ParentPolicy::Strategy.new(name: json["name"].to_s, allowed: Array(json["allowed"]).map(&:to_s).freeze,
                                               origin: (json["origin"] || "config").to_sym)
      end

      # chi web's answer/dismiss reply as the worker's Bridge would have
      # given it: 503 not_live is no worker (nil), 504 the Bridge's 408, 501
      # not_supported its 404 for a route it lacks, 409 question_not_pending
      # its 409; the rest as it came.
      def bridge_reply(reply)
        json = reply.json.is_a?(Hash) ? reply.json : {}
        case [reply.status, json["error"]]
        in [503, "not_live"] then nil
        in [404, "not_found"] then nil
        in [504, _] then BridgeClient::Response.new(status: 408, body: reply.body)
        in [501, "not_supported"] then BridgeClient::Response.new(status: 404, body: JSON.generate(json.merge("error" => "not_found")))
        else BridgeClient::Response.new(status: reply.status, body: reply.body)
        end
      end

      def context_added(reply)
        return if reply.status == 201

        case reply.error
        when "exists", "invalid_source", "invalid_json" then raise ContextSources::Invalid, reply.json["detail"].to_s
        else raise_refusal(reply)
        end
      end

      def context_entry_of(row, text: nil)
        source = ContextSources::Source.from_h(row["source"] || {})
        snapshot = ContextSources::Snapshot.from_h((row["snapshot"] || {}).merge("text" => text))
        ContextEntry.new(source: source, snapshot: snapshot, muted: row["muted"], shadowed: row["shadowed"],
                         unread: row["unread"])
      end

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
        when Array then value.map { |item| symbolize(item) }
        else value
        end
      end
    end
  end
end
