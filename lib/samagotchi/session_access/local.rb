# frozen_string_literal: true

require "socket"

require_relative "../session"
require_relative "../session_access"
require_relative "../reply_wait"
require_relative "../bridge_client"
require_relative "../owner_lock"
require_relative "../parent_report"
require_relative "../note_delivery"
require_relative "../image_store"
require_relative "../context_sources"
require_relative "../send_command/busy"
require_relative "../chi_invocation"
require_relative "../worker_sidecar"
require_relative "../worker_link"
require_relative "../review_start"
require_relative "../launch_mode"
require_relative "../participants"
require_relative "../config"
require_relative "../web/grants"
require_relative "../web/info_probe"
require_relative "../web/public_url"
require_relative "../web/link_codes"
require_relative "../web/running"

module Samagotchi
  # Loaded on first use: SessionManager and its ~80 files only when a
  # command reaches it (chi context never does).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module SessionAccess
    # This machine's sessions: the calls the session commands made before
    # the seam, moved here unchanged. The errors are the callees' own
    # (ArgumentError and Session::AmbiguousId for an id, SessionManager's
    # refusals), which the commands word.
    class Local
      # @param state_dir [String, nil] the sessions' folder; nil: the
      #   callees' own default (Session.default_state_dir), and no
      #   state_dir: is passed on (chi sessions stop/restart/list)
      def initialize(state_dir: nil)
        @state_dir = state_dir
      end

      def remote? = false

      # This machine's sessions are the owner's.
      def participant? = false

      # The printed commands' spelling: this machine's chi.
      # @return [ChiInvocation]
      def invocation = ChiInvocation::HERE

      # --- ids and sessions

      # The full id of +given+ (an id or a unique prefix); the session
      # need not exist (Session.resolve_id).
      # @raise [Session::AmbiguousId]
      def resolve_id(given) = Session.resolve_id(given, **dir)

      # The full id of +given+, of a session that exists.
      # @raise [ArgumentError] no such session (Session::AmbiguousId: a
      #   prefix of several)
      def resolve(given)
        id = resolve_id(given)
        show(id)
        id
      end

      # @return [Session]
      # @raise [ArgumentError] no such session
      def show(id) = Session.load(id, **dir)

      # @return [OwnerLock::Owner, nil] the worker or chi REPL that owns it
      def owner(id) = SessionManager.session_owner(id, **dir)

      # SessionManager.list_sessions: Session objects, for chi sessions list.
      def list(**filters) = SessionManager.list_sessions(**filters, **dir)

      # SessionManager.session_summaries: the summary hashes (chi sessions
      # list --live/--format, chi note --all).
      def summaries(**filters) = SessionManager.session_summaries(**filters, **dir)

      # The session's worker for an attach: the live one as is, else
      # resumed and waited for up to +wait+ seconds (chi --attach on this
      # machine; chi web's POST …/wake for a remote one). A worker still
      # leaving (its Bridge closed, its recap on leave being written) is
      # waited for first (OwnerLock.await_release: its recap's timeout and
      # a margin), so the resume finds the session free.
      # @return [Woken] its sidecar nil when the Bridge didn't come in time
      # @raise [ArgumentError] no such session
      # @raise [Refused] code scratch: a leftover chi scratch session
      # @raise [SessionManager::OwnedByTUI] a chi REPL has it
      def wake(id, wait:)
        session = show(id)
        raise Refused.new(LaunchMode::SCRATCH_LEFTOVER, code: "scratch") if session.scratch

        link = WorkerLink.resolve(session_dir(id), unlink: true)
        case link
        when WorkerLink::Live then return Woken.new(woke: false, sidecar: link.sidecar)
        when WorkerLink::Skew then raise Refused.new(link.message(id), code: "worker_newer")
        when WorkerLink::Starting
          # A worker that never publishes its Bridge (a failed start, a
          # crash's teardown) lets go of the lock: then resume, not 504.
          found = WorkerLink.await(id, session_dir: session_dir(id), timeout: wait,
                                       give_up: ->(link) { !link.worker_owned? })
          return Woken.new(woke: false, sidecar: found.live? ? found.sidecar : nil) if found.worker_owned?
        end

        OwnerLock.await_release(session_dir(id))
        SessionManager.resume_session(id, **dir)
        found = WorkerLink.await(id, session_dir: session_dir(id), timeout: wait)
        Woken.new(woke: true, sidecar: found.live? ? found.sidecar : nil)
      end

      # The session's worker now, never started (chi web's GET …/worker).
      # @return [WorkerState]
      # @raise [ArgumentError] no such session
      def worker(id)
        show(id)
        WorkerState.new(link: WorkerLink.resolve(session_dir(id), unlink: true),
                        stopped: Session.stopped_marker?(id, state_dir: state_dir!))
      end

      # --- create and send

      # @param spec [NewSession]
      # @return [Session] the session created (its id, model_warning,
      #   continues, moved_children)
      # @raise [SessionContinue::Refused, SessionManager::ArchiveRefused,
      #   SessionManager::OwnedByTUI, ReviewStart::Refused] refused;
      #   StandardError: could not start
      def create(spec)
        return create_review(spec) if spec.review

        start = spec.preview ? { prompt: spec.prompt, preview: spec.preview } : { prompt: spec.prompt }
        if spec.continues
          return SessionManager.continue_session(spec.continues, **start, model: spec.model_name, **dir)
        end

        SessionManager.spawn_session(**start, working_directory: spec.working_directory, model_name: spec.model_name,
                                              setup: spec.setup, **dir)
      end

      # A review session (ReviewStart): a fork of review.from, or a fresh
      # one in the spec's folder.
      def create_review(spec)
        review = spec.review
        if review.from
          return ReviewStart.fork(from: review.from, subjects: review.subjects, model: spec.model_name, state_dir: state_dir!)
        end

        ReviewStart.start(subjects: review.subjects, dir: spec.working_directory || Dir.pwd, model: spec.model_name,
                          setup: spec.setup || SessionSetup.new, state_dir: state_dir!)
      end

      # Whether a just-created session's worker came up (its Bridge
      # answers) within +timeout+ seconds.
      def await_worker(id, timeout:)
        WorkerLink.await(id, session_dir: session_dir(id), timeout: timeout).live?
      end

      # Copies of +refs+ (ImageStore refs stored in +from+) in the
      # session's folder, as the refs a turn takes.
      # @return [Array<Hash>] {file:, name:} each
      def upload_images(id, refs, from:)
        to = session_dir(id)
        refs.map do |ref|
          ImageStore.copy_file(ref, from: from, to: to)
          { file: ref[:file], name: ref[:name] }
        end
      end

      # @return [SessionManager::DeliverResult]
      # @raise [SessionManager::OwnedByTUI] a chi REPL owns it
      def deliver_turn(id, prompt:, client_id:, images:, delivery: nil)
        SessionManager.deliver_turn(id, prompt: prompt, client_id: client_id, images: images, delivery: delivery, **dir)
      end

      # @return [NoteDelivery::Result]
      def note(id, text:, source:)
        NoteDelivery.deliver(id, text: text, source: source, state_dir: state_dir!)
      end

      # --- waiting for the reply

      # What a wait needs from before anything is sent (WaitStart).
      # @param session [Session, nil] the session as the caller just read
      #   it (its checks and the baseline then see the same state); nil
      #   reads it here
      # @param question_id [String, nil, :pending] the question the
      #   baseline counts as already reported (ReplyWait.baseline_of);
      #   :pending, the one pending now
      # @param turn [String, nil] a turn asked for (--turn): known_turn
      #   says whether it can be waited for
      # @param created [Boolean] +session+ was just created: no reply, no
      #   question and no ended turn yet, nothing else read (read later, as
      #   chi web's prepare route does, its first turn may have ended: that
      #   end is the answer, not the baseline's)
      # @return [WaitStart]
      def prepare_wait(id, session: nil, question_id: :pending, turn: nil, created: false)
        session ||= show(id)
        if created
          return WaitStart.new(cursor: nil, baseline: ReplyWait::Baseline.new(messages: session.messages.size),
                               own_turn: nil, known_turn: nil, running: false, live: false, settled: false,
                               last_turn_id: nil)
        end

        cursor = ReplyWait.newest_reply(id, state_dir: state_dir!)
        baseline = question_id == :pending ? ReplyWait.baseline_of(session) : ReplyWait.baseline_of(session, question_id: question_id)
        session_dir = session_dir(id)
        running = session.status == Session::STATUS_RUNNING
        WaitStart.new(
          cursor: cursor, baseline: baseline, own_turn: ReplyWait.own_turn(session, session_dir: session_dir),
          known_turn: (ReplyWait.known_turn?(session, session_dir: session_dir, turn: turn) if turn),
          running: running, live: running || !owner(id).nil?,
          settled: session.status == Session::STATUS_IDLE && !session.last_turn.nil? && session.pending_question.nil?,
          last_turn_id: session.last_turn&.enqueued_id
        )
      end

      # Why chi send --wait may not send into the session now (a turn runs,
      # or a question waits on it with --queue), or nil.
      # @param session [Session, nil] the session as the caller just read
      #   it; nil reads it here
      # @return [SendCommand::Busy, nil]
      def busy(id, queue:, session: nil)
        session ||= show(id)
        owner = owner(id) if session.status == Session::STATUS_RUNNING
        SendCommand::Busy.for(session, owner: owner, queue: queue)
      end

      # ReplyWait.call: blocks until the reply, a question, the turn's end
      # or +timeout+.
      # @return [ReplyWait::Result]
      # @raise [ArgumentError] the session is gone
      def wait_reply(id, **)
        ReplyWait.call(id, state_dir: state_dir!, **)
      end

      # What a parent may pick on the session's questions: this machine's
      # guardrails.parent_answers tightened by the session's own
      # (ParentReport.strategy_for).
      def parent_strategy(id) = ParentReport.strategy_for(id, state_dir: state_dir!)

      # --- questions

      # The answer posted to the session's worker (its Bridge), once more
      # after a 408.
      # @return [BridgeClient::Response, nil] the Bridge's reply; nil when
      #   no worker runs it
      # @raise [SystemCallError, IOError, SocketError] the worker went away
      def answer(id, question_id:, selected:, freeform:, client_id:)
        on_worker(id) { |client| client.answer(id: question_id, selected: selected, freeform: freeform, client_id: client_id) }
      end

      # The question dismissed on the session's worker; as #answer.
      def dismiss(id, question_id:)
        on_worker(id) { |client| client.dismiss_question(id: question_id) }
      end

      # --- sessions

      # @return [Boolean] whether the worker released the session
      def stop(id, wait:) = SessionManager.stop_session(id, wait: wait, **dir)

      # @return [SessionManager::RestartResult]
      def restart(id) = SessionManager.restart_session(id, **dir)

      # @return [Hash] SessionManager.archive_session's
      def archive(id) = SessionManager.archive_session(id, **dir)

      # @return [Hash] SessionManager.unarchive_session's
      def unarchive(id) = SessionManager.unarchive_session(id, **dir)

      # @param force [Boolean] stop a live worker first (else refused)
      # @return [Hash] SessionManager.delete_session's
      def delete(id, force:) = SessionManager.delete_session(id, stop: force, **dir)

      # --- context (a session's sources, or a project's: local only)
      #
      # +target+ is chi context's Target (session_id, project_root; a
      # project's when session_id is nil).

      # Attaches +source+ to the target's own sources.
      def context_add(target, source)
        location = context_location(target)
        location.add(source.with(scope: location.scope))
        nil
      end

      # New text for the target's --push source +name+.
      # @param fetched [ContextSources::Fetched]
      # @return [ContextPush]
      def context_push(target, name, fetched)
        attached = context_attached(target, name) or return ContextPush.new(status: :missing)
        return ContextPush.new(status: :not_push) unless attached.source.push?

        before, written = attached.location.locked(name) do
          [attached.location.snapshot(name).revision, attached.location.record_text(name, fetched)]
        end
        ContextPush.new(status: :pushed, before: before, revision: written.revision)
      end

      # The target's sources: a session's own, then its project's (shadowed
      # ones too, marked), muted and unread; a project's own.
      # @return [Array<ContextEntry>]
      def context_entries(target)
        if target.project?
          location = context_location(target)
          return location.sources.map { |source| ContextEntry.new(source: source, snapshot: location.snapshot(source.name)) }
        end

        own = context_location(target)
        subs = own.subscriptions
        attached_to(target, shadowed: true).map do |a|
          snapshot = a.snapshot
          read = subs[a.name]&.read
          ContextEntry.new(source: a.source, snapshot: snapshot, muted: own.muted?(a.name), shadowed: a.shadowed,
                           unread: snapshot.text? && read != snapshot.revision)
        end
      end

      # The source +name+ as the target sees it, with its snapshot.
      # @return [ContextEntry, nil]
      def context_entry(target, name)
        attached = context_attached(target, name) or return nil
        ContextEntry.new(source: attached.source, snapshot: attached.snapshot)
      end

      # Detaches the target's own source +name+.
      # @return [Symbol] :removed, :project (a session's project has it:
      #   rm --project, or mute it) or :missing
      def context_remove(target, name)
        ContextSources.check_name!(name)
        return :removed if context_location(target).remove(name)

        project = !target.project? && ContextSources.project_location_for(target.project_root, state_dir: @state_dir)
        project&.source(name) ? :project : :missing
      end

      # Local only (chi context refresh, mute, unmute, which work on the
      # files here; Contract: local_only): the source +name+ as the target
      # sees it, with the folder it lives in.
      # @return [ContextSources::Attached, nil]
      def context_attached(target, name)
        ContextSources.check_name!(name)
        if target.project?
          location = context_location(target)
          source = location.source(name)
          return source && ContextSources::Attached.new(source: source, location: location, shadowed: false)
        end

        attached_to(target).find { |a| a.name == name }
      end

      # Local only, as #context_attached: the folder a target's own sources
      # live in.
      def context_location(target)
        if target.project?
          ContextSources.project_location_for(target.project_root, state_dir: @state_dir)
        else
          ContextSources.session_location(target.session_id, state_dir: @state_dir)
        end
      end

      # --- participants (chi share)

      # Remote's: through this machine's grants store, as chi web would.
      # @return [Array<ParticipantView>]
      def participants(id = nil)
        grants.list(session_id: id).map { |grant| ParticipantView.from_h(grant.public_h(grants.now)) }
      end

      # The link names this machine's chi web: web.public_url from this
      # machine's config (never what the port answers) when it is set, or
      # the one a running chi web --tunnel recorded (the code in the
      # fragment, as chi web's own invite), else its LAN address
      # and port when one runs on the LAN (the port it recorded, else
      # web.port), else 127.0.0.1 (+lan+ false: the link opens on this
      # machine only).
      # A grant bound to +identity+ needs that public_url with an identity
      # header (Participants.invite).
      # @return [Invitation]
      # @raise [ArgumentError] no such session
      # @raise [BadRequest] a bad name, kind, ttl or identity, an archived
      #   session, an identity with no proxy to check it
      def invite(id, name:, kind:, ttl: nil, cap: nil, identity: nil)
        public_url = configured_public_url
        issued = Participants.invite(grants, session_id: id, name: name, kind: kind, ttl: ttl, cap: cap,
                                             identity: identity, public_url: public_url, state_dir: state_dir!)
        web = public_url ? nil : local_web
        link = if public_url then public_url.link(link_code(issued), "s=#{id}")
               else "http://#{web.ip || "127.0.0.1"}:#{web.port}/?token=#{issued.token}#s=#{id}"
               end
        Invitation.new(participant: ParticipantView.from_h(issued.grant.public_h(grants.now)), token: issued.token,
                       link: link, lan: !public_url.nil? || !web.ip.nil?,
                       warning: ReviewStart.share_warning(Session.load(id, **dir)))
      rescue Web::Grants::Invalid => e
        raise BadRequest.new(e.message, code: "invalid_participant")
      end

      # The header this machine's chi web names the signed-in user in (a
      # link can be bound to an email: chi share --identity), nil when it
      # has no such proxy: config's web.public_url with
      # web.proxy.identity_header, or a running chi web --tunnel's.
      # @return [String, nil]
      def identity_header = configured_public_url&.identity_header

      # @return [Array<ParticipantView>] the ones it revoked
      def revoke_participants(id = nil, participant: nil)
        Participants.revoke(grants, session_id: id, id: participant, state_dir: state_dir!)
                    .map { |grant| ParticipantView.from_h(grant.public_h(grants.now)) }
      end

      # @return [ParticipantView] the participant with their new cap
      # @raise [BadRequest] a cap out of range, or no such active participant
      def set_participant_cap(id, participant:, cap:)
        grant = Participants.set_cap(grants, session_id: id, id: participant, cap: cap, state_dir: state_dir!)
        raise BadRequest.new(Participants.no_participant(participant, id), code: "invalid_participant") unless grant

        ParticipantView.from_h(grant.public_h(grants.now))
      rescue Web::Grants::Invalid => e
        raise BadRequest.new(e.message, code: "invalid_participant")
      end

      private

      def grants = @grants ||= Web::Grants.new(Web::Grants.path(state_dir: state_dir!))

      # Web::Server::DEFAULT_PORT, without loading chi web.
      WEB_PORT = 4567
      LOCAL_PROBE_TIMEOUT = 1.0

      # Where this machine's chi web answers (GET /api/info): its LAN ip
      # (nil without one) and the port the running one recorded
      # (Web::Running) when a chi web answers there, else config's web.port.
      LocalWeb = Data.define(:ip, :port)

      # The LAN address a probe answered, only if it is one of this
      # machine's: whatever listens on the port may be another user's
      # listener naming its own (nil then: the link names 127.0.0.1).
      def own_address(ip)
        return nil unless ip.is_a?(String)

        Socket.ip_address_list.any? { |addr| addr.ip_address == ip } ? ip : nil
      end

      # A one-time code for the grant's link (Web::LinkCodes), until it expires.
      def link_code(issued)
        ttl = [Time.iso8601(issued.grant.expires_at) - grants.now, 1].max
        Web::LinkCodes.for_grants(grants.path).issue(kind: :grant, token: issued.token, ttl: ttl)
      end

      # web.public_url as this machine's config has it (nil when not a
      # valid one: chi web refuses to start on that), else the one the
      # running chi web recorded (chi web --tunnel's), only while that same
      # process answers on its port (Web::Running.live_public_url).
      def configured_public_url
        configured = Config.get("web.public_url")
        return Web::Running.live_public_url(path: Web::Running.path(state_dir: state_dir!)) if configured.to_s.strip.empty?

        Web::PublicUrl.from_config(url: configured, identity_header: Config.get("web.proxy.identity_header"))
      rescue Web::PublicUrl::Invalid
        nil
      end

      def local_web
        configured = Config.get("web.port").to_s.to_i
        configured = WEB_PORT unless configured.positive?
        recorded = Web::Running.port(path: Web::Running.path(state_dir: state_dir!))
        [recorded, configured].compact.uniq.each do |port|
          info = Web::InfoProbe.call("127.0.0.1", port, timeout: LOCAL_PROBE_TIMEOUT)
          return LocalWeb.new(ip: own_address(info["lan"]), port: port) if info.is_a?(Hash)
        end
        LocalWeb.new(ip: nil, port: configured)
      end

      def dir = @state_dir ? { state_dir: @state_dir } : {}
      def state_dir! = @state_dir || Session.default_state_dir
      def session_dir(id) = Session.session_dir(id, state_dir: state_dir!)

      def attached_to(target, shadowed: false)
        ContextSources.attached(target.session_id, project_root: target.project_root, state_dir: @state_dir,
                                                   shadowed: shadowed)
      end

      # The block's post to the session's live worker, again on a 408 (the
      # worker didn't take it in time).
      def on_worker(id)
        client = WorkerLink.client(id, session_dir: session_dir(id)) or return nil
        reply = nil
        2.times do
          reply = yield client
          break unless reply.status == 408
        end
        reply
      end
    end
  end
end
