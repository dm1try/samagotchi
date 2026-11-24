# frozen_string_literal: true

require "fileutils"
require "socket"

require_relative "../session"
require_relative "../session_access"
require_relative "../reply_wait"
require_relative "../bridge_client"
require_relative "../owner_lock"
require_relative "../parent_report"
require_relative "../note_delivery"
require_relative "../image_store"
require_relative "../context_candidates"
require_relative "../worker_inbound"
require_relative "../context_sources"
require_relative "../peer_exchanges"
require_relative "../peer_mailbox"
require_relative "../peer_receipts"
require_relative "../peer_roster"
require_relative "../peer_say"
require_relative "../archive_store"
require_relative "../session_chain"
require_relative "../send_command/busy"
require_relative "../chi_invocation"
require_relative "../worker_sidecar"
require_relative "../worker_link"
require_relative "../worker_presence"
require_relative "../share_terms"
require_relative "../launch_mode"
require_relative "../participants"
require_relative "../config"
require_relative "../live_versions"
require_relative "../grants"
require_relative "../log"
require_relative "../web/info_probe"
require_relative "../web/public_url"
require_relative "../web/link_codes"
require_relative "../web/running"

module Samagotchi
  # Loaded on first use: SessionManager and its ~80 files only when a
  # command reaches it (chi context never does).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)
  # A continue (#create with continues); it requires session_manager.
  autoload :SessionContinue, File.expand_path("../session_continue", __dir__)

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

      # The full id of +given+, of a session that exists (and loads).
      # @raise [Session::NotFound] no such session (Session::AmbiguousId: a
      #   prefix of several)
      def resolve(given)
        id = Session.resolve!(given, **dir)
        show(id)
        id
      end

      # @return [Session]
      # @raise [ArgumentError] no such session
      def show(id) = Session.load(id, **dir)

      # Where input for +id+ goes: its chain's newest link when it was
      # continued (SessionInbox::Head's send walk; :continuing while a
      # continue of it is in flight), else +id+.
      # @return [SessionInbox::Resolved]
      def head(id) = SessionInbox::Head.resolve(:send, id, state_dir: state_dir!)

      # @return [OwnerLock::Owner, nil] the worker or one-turn chi run that owns it
      def owner(id) = SessionManager.session_owner(id, **dir)

      # Whether +turn+ (an enqueued id) waits as an unclaimed input file of
      # session +id+ (Ask's request_id check: such a turn with no worker
      # running is delivered again, which wakes one; the worker runs the id
      # once). This machine's only: Remote never takes a request_id.
      def waiting_turn?(id, turn) = !SessionInbox.waiting_input(session_dir(id), turn).nil?

      # SessionManager.session_rows: the SessionRows chi sessions list
      # prints and chi note --all reaches (chi web's summaries route answers
      # their #to_summary_h).
      # @return [Array<SessionRow>]
      def summaries(**filters) = SessionManager.session_rows(**filters, **dir)

      # The session's worker for an attach: the live one as is, else
      # resumed and waited for up to +wait+ seconds (chi --attach on this
      # machine; chi web's POST …/wake for a remote one). A worker still
      # leaving (its Bridge closed, its recap on leave being written) is
      # waited for first (OwnerLock.await_release: its recap's timeout and
      # a margin), so the resume finds the session free.
      # @return [Woken] its sidecar nil when the Bridge didn't come in time
      # @raise [ArgumentError] no such session
      # @raise [Refused] code scratch: a chi scratch session (its terminal's alone)
      # @raise [SessionManager::OwnedByTUI] a one-turn chi run has it
      def wake(id, wait:)
        session = show(id)
        raise Refused.new(Session::SCRATCH_REFUSED, code: "scratch") if session.scratch

        link = WorkerPresence.read(id, state_dir: state_dir!, link: :unlink).link
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
        presence = WorkerPresence.read(id, state_dir: state_dir!, link: :unlink)
        WorkerState.new(link: presence.link, stopped: presence.stop_marked?)
      end

      # --- create and send

      # @param spec [NewSession]
      # @return [Session] the session created (its id, model_warning,
      #   continues, moved_children)
      # @raise [SessionContinue::Refused, SessionManager::ArchiveRefused,
      #   SessionManager::OwnedByTUI] refused;
      #   StandardError: could not start
      def create(spec)
        start = spec.preview ? { prompt: spec.prompt, preview: spec.preview } : { prompt: spec.prompt }
        if spec.continues
          return SessionContinue.run(spec.continues, **start, model: spec.model_name, client_id: spec.client_id, **dir)
        end

        driver = spec.driver ? { driver: spec.driver } : {}
        SessionManager.spawn_session(**start, working_directory: spec.working_directory, model_name: spec.model_name,
                                              setup: spec.setup, client_id: spec.client_id, **driver, **dir)
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
          target = File.join(to, ref[:file].to_s)
          (@uploaded ||= Set.new) << target unless File.exist?(target)
          ImageStore.copy_file(ref, from: from, to: to)
          { file: ref[:file], name: ref[:name] }
        end
      end

      # Takes back the copies #upload_images made of +refs+ in the session
      # (a send its delivery refused: chi send's link_continued): only the
      # files it wrote, never one there before (a name is its content's
      # hash, so an earlier turn's image may share it).
      def discard_images(id, refs)
        dir = session_dir(id)
        refs.each do |ref|
          target = File.join(dir, ref[:file].to_s)
          FileUtils.rm_f(target) if @uploaded&.delete?(target)
        end
      end

      # @return [SessionManager::DeliverResult]
      # @raise [SessionManager::OwnedByTUI] a one-turn chi run owns it
      # @param follow [Boolean] +id+ is the head #head resolved (SessionManager.deliver_turn's follow:)
      # @param manager [#resume_session, nil] the manager that starts its
      #   worker; nil: SessionManager's own default
      # @param bridge [#call, nil] the worker's Bridge client (chi web's
      #   live_bridge_client: POST …/ask delivers as POST …/turn does); nil:
      #   SessionManager's own wait
      # @param enqueued_id [String, nil] the turn's id (an ask's request_id's);
      #   nil: SessionManager mints one
      # @param anchors [TurnAnchors, Hash, nil] what the turn points at
      #   (SessionManager.deliver_turn's anchors:); nil: none
      def deliver_turn(id, prompt:, client_id:, images:, delivery: nil, follow: false, manager: nil, bridge: nil,
                       enqueued_id: nil, anchors: nil)
        routing = { manager: manager, bridge: bridge, enqueued_id: enqueued_id, anchors: anchors }.compact
        SessionManager.deliver_turn(id, prompt: prompt, client_id: client_id, images: images, delivery: delivery,
                                        follow: follow, **routing, **dir)
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
      # @param within [Numeric, nil] the most seconds for it all (an MCP
      #   call's, under its host's limit): each try's read timeout is cut
      #   to it, and a 408 is tried again only when a whole try still fits
      # @return [BridgeClient::Response, nil] the Bridge's reply; nil when
      #   no worker runs it
      # @raise [SystemCallError, IOError, SocketError] the worker went away
      def answer(id, question_id:, selected:, freeform:, client_id:, within: nil)
        on_worker(id, within: within) do |client|
          client.answer(id: question_id, selected: selected, freeform: freeform, client_id: client_id)
        end
      end

      # The question dismissed on the session's worker; as #answer.
      def dismiss(id, question_id:)
        on_worker(id) { |client| client.dismiss_question(id: question_id) }
      end

      # --- sessions

      # @return [Boolean] whether the worker released the session
      def stop(id, wait:) = SessionManager.stop_session(id, wait: wait, **dir)

      # @return [SessionManager::Restarted]
      def restart(id) = SessionManager.restart_session(id, **dir)

      # @return [SessionManager::ArchiveResult]
      # @param stop_tasks [Boolean] stop the background tasks it or a
      #   delegate started that still run (else ArchiveRefused :tasks_running)
      def archive(id, stop_tasks: false) = SessionManager.archive_session(id, running_tasks: tasks_policy(stop_tasks), **dir)

      # @return [Hash] SessionManager.unarchive_session's
      def unarchive(id) = SessionManager.unarchive_session(id, **dir)

      # @param force [Boolean] stop a live worker first (else refused)
      # @return [Hash] SessionManager.delete_session's
      # A user's delete: SessionManager.delete_session's revive_previous: and
      # refuse_continuing: (D2/D5), on unless told otherwise.
      # @param stop_tasks [Boolean] stop the background tasks the deleted
      #   sessions started that still run (else DeleteRefused :tasks_running)
      def delete(id, force:, stop_tasks: false, revive_previous: true, refuse_continuing: true)
        SessionManager.delete_session(id, stop: force, revive_previous: revive_previous,
                                          refuse_continuing: refuse_continuing, running_tasks: tasks_policy(stop_tasks), **dir)
      end

      # Every link of the chain (SessionManager.delete_chain).
      def delete_chain(id, force:, stop_tasks: false)
        SessionManager.delete_chain(id, stop: force, running_tasks: tasks_policy(stop_tasks), **dir)
      end

      # What #delete (+chain+: #delete_chain) would do now, deleting
      # nothing (chi sessions delete --dry-run): the web sheet's plan.
      # A folder whose session file is gone has a plan too (chi web's
      # route answers for it); neither on disk is no session.
      # @return [DeletePlan::Plan]
      # @raise [Session::NotFound]
      def delete_plan(id)
        raise Session::NotFound, id unless File.exist?(Session.session_file(id, state_dir: state_dir!)) || Dir.exist?(session_dir(id))

        require_relative "../session_chain/delete_preview"
        DeletePlan.read(SessionChain::Delete::Preview.call(id, state_dir: state_dir!))
      end

      # A user's delete or archive: REFUSE, or a stop by "user".
      private def tasks_policy(stop_tasks)
        policies = SessionManager::RunningTasks::Policy
        stop_tasks ? policies.stop(by: "user") : policies::REFUSE
      end

      # --- context (a session's sources, or a project's: local only)
      #
      # +target+ is chi context's Target (session_id, project_root; a
      # project's when session_id is nil).

      # Attaches +source+ to the target's own sources.
      # @return [ContextAdded]
      def context_add(target, source)
        location = context_location(target)
        location.add(source.with(scope: location.scope))
        ContextAdded.new(name: source.name)
      end

      # New text for the target's --push source +name+. Refused, nothing
      # written, when the session was continued (its writer holds a stale
      # id): a source of its own, or none of the name. A project's source
      # takes it (the next link sees it too).
      # @param fetched [ContextSources::Fetched]
      # @return [ContextPush]
      def context_push(target, name, fetched)
        attached = context_attached(target, name)
        if !target.project? && (attached.nil? || attached.location.session?) &&
           (next_id = continued_as(target.session_id))
          return ContextPush.new(status: :continued, next_id: next_id)
        end
        return ContextPush.new(status: :missing) unless attached
        return ContextPush.new(status: :not_push) unless attached.source.push?

        record = lambda do
          attached.location.locked(name) do
            before = attached.location.snapshot(name).revision
            [before, attached.location.record_text(name, fetched)]
          end
        end
        unless !target.project? && attached.location.session? && attached.source.scope == "session"
          before, written = record.call
          return ContextPush.new(status: :pushed, before: before, revision: written.revision)
        end

        push_delivery(target.session_id, name, fetched, attached.location, record)
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

      # A session's candidates with their status; none for a project.
      # @return [Array<ContextCandidate>]
      def context_candidates(target)
        return [] if target.project?

        ContextCandidates.with_status(target.session_id, project_root: target.project_root, project_id: target.project_id,
                                                         state_dir: @state_dir)
                         .map { |candidate, status| ContextCandidate.new(candidate: candidate, status: status) }
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

        project = !target.project? && ContextSources.project_location_for(target.project_root,
                                                                          project_id: target.project_id,
                                                                          state_dir: @state_dir)
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
          ContextSources.project_location_for(target.project_root, project_id: target.project_id, state_dir: @state_dir)
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
      # @raise [BadRequest] a bad name, ttl or identity, an archived
      #   session, an identity with no proxy to check it
      def invite(id, name:, ttl: nil, cap: nil, identity: nil)
        public_url = configured_public_url
        # No link while the live worker would refuse every turn of theirs.
        terms = ShareTerms.of(Session.load(id, **dir), state_dir: state_dir!)
        raise BadRequest.new(terms.refusal, code: "worker_too_old") if terms.refusal

        issued = Participants.invite(grants, session_id: id, name: name, ttl: ttl, cap: cap,
                                             identity: identity, public_url: public_url, state_dir: state_dir!)
        web = public_url ? nil : local_web
        link = if public_url then public_url.link(link_code(issued), "s=#{id}")
               else "http://#{web.ip || "127.0.0.1"}:#{web.port}/?token=#{issued.token}#s=#{id}"
               end
        Invitation.new(participant: ParticipantView.from_h(issued.grant.public_h(grants.now)), token: issued.token,
                       link: link, lan: !public_url.nil? || !web.ip.nil?,
                       warning: terms.warning)
      rescue Grants::Invalid => e
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
      rescue Grants::Invalid => e
        raise BadRequest.new(e.message, code: "invalid_participant")
      end

      # --- peers (PeerMailbox: the peer's side; PeerReceipts: the worker's)

      # Pairs +peer+ with session +id+ (link.json). Refused, nothing
      # written, when the session was continued or a live worker of it
      # doesn't take the peer mail (a pairing to it would look done and
      # not work).
      # @return [PeerPaired]
      # @raise [PeerMailbox::Invalid] a bad name
      # @raise [Session::NotFound] no such session
      def peer_pair(id, peer, address:, from:)
        PeerMailbox.check_name!(peer)
        raise Session::NotFound, id unless Session.exist?(id, **dir)
        if (next_id = continued_as(id))
          return PeerPaired.new(status: :continued, next_id: next_id)
        end
        return PeerPaired.new(status: :old_worker) if old_peer_worker?(id)

        link = PeerMailbox.pair(id, peer, address: address, from: from, state_dir: state_dir!)
        location = ContextSources.session_location(id, state_dir: state_dir!)
        # These are exactly the bundles' LEGACY_INBOX and LEGACY_OUTBOX names.
        ["#{peer}-inbox", "#{peer}-outbox"].each do |name|
          location.remove(name)
        rescue SystemCallError
          nil
        end
        PeerPaired.new(status: :paired, link: link)
      end

      # Ends the pairing (link.json); the messages stay.
      # @return [Boolean] whether there was one
      def peer_unpair(id, peer) = PeerMailbox.unpair(id, peer, state_dir: state_dir!)

      # @return [Array<PeerRoster::Peer>]
      def peer_list(id) = PeerRoster.build(id, state_dir: state_dir!)

      # A message from +peer+ into session +id+, as a delivery
      # (SessionInbox.deliver :peer): refused before anything is written
      # for a gone session, a continued one, no pairing, a live worker
      # without the peer mail, UNTAKEN_MAX unread; else written inside the
      # delivery's block (a session being deleted refuses first), which
      # asks for a worker by the message's own +wake+ alone (no
      # context.wake, no window). Then what chi did, at once when it can't
      # answer yet, else the receipt within +wait+ seconds (a look every
      # PeerSay::POLL_SECONDS).
      # @return [PeerSay]
      # @raise [PeerMailbox::Invalid] a bad name, an empty or oversized text
      def peer_say(id, peer, text:, summary:, wake:, re:, wait: 0, sleeper: ->(seconds) { sleep(seconds) },
                   clock: -> { monotonic })
        PeerMailbox.check_name!(peer)
        PeerMailbox.checked_text(text)
        return PeerSay.new(status: :gone) unless Session.exist?(id, **dir)
        if (next_id = continued_as(id))
          return PeerSay.new(status: :continued, next_id: next_id)
        end
        return PeerSay.new(status: :not_paired) unless PeerMailbox.link(id, peer, state_dir: state_dir!)
        return PeerSay.new(status: :old_worker) if old_peer_worker?(id)

        message = nil
        start_failed = false
        delivered = begin
          SessionInbox.deliver(:peer, id, state_dir: state_dir!) do
            message = PeerMailbox.post(id, peer, text: text, summary: summary, wake: wake, re: re, state_dir: state_dir!,
                                                 taken: PeerReceipts.taken(id, peer, state_dir: state_dir!))
            message.wake
          end
        rescue PeerMailbox::Full
          return PeerSay.new(status: :full)
        rescue StandardError => e
          raise unless message

          Log.exception(:peer, "peer_say_wake_failed", e, sid: id, peer: peer)
          start_failed = true
          nil
        end
        return PeerSay.new(status: delivered.wake == :deleting ? :deleting : :gone) if delivered&.refused?

        at_once = start_failed ? :start_failed : peer_at_once(id, delivered.wake)
        receipt = at_once ? nil : peer_receipt_within(id, peer, message.serial, wait, sleeper, clock)
        peer_said(id, peer, message.serial, at_once, receipt)
      end

      private

      # Whether +id+'s live worker doesn't take the peer mail (its Bridge
      # features: a read-only look). No live worker: nil (the next one does).
      def old_peer_worker?(id)
        features = WorkerLink.live_features(id, state_dir: state_dir!)
        features && !features.include?(PeerMailbox::FEATURE)
      end

      # What a say says without waiting (PeerSay::AT_ONCE), from the
      # delivery's +wake+ and the session; nil when a worker sees the
      # message now and the say may wait for its receipt.
      def peer_at_once(id, wake)
        case wake
        when :stopped, :archived, :owned, :starting, :deleting then wake
        when :scratch then :start_failed
        when :live, :woken
          session = Session.load(id, **dir)
          started = Array(session.messages).any? { |m| %w[user assistant model].include?((m[:role] || m["role"]).to_s) }
          return :no_turn unless started

          :running if wake == :live && session.status == Session::STATUS_RUNNING
        else :not_running
        end
      end

      # The worker's receipt for +serial+, looked at until one comes or
      # +wait+ seconds pass (one look for 0).
      # @return [PeerReceipts::Receipt, nil]
      def peer_receipt_within(id, peer, serial, wait, sleeper, clock)
        deadline = clock.call + wait.to_f
        loop do
          receipt = PeerReceipts.receipt(id, peer, serial, state_dir: state_dir!)
          return receipt if receipt

          left = deadline - clock.call
          return nil unless left.positive?

          sleeper.call([PeerSay::POLL_SECONDS, left].min)
        end
      end

      # The say's PeerSay: the peer's other held messages read now, and the
      # turns a held reason counts, as configured here.
      def peer_said(id, peer, serial, at_once, receipt)
        latest = PeerReceipts.read(id, state_dir: state_dir!).peer(peer).receipts.to_h { |item| [item.serial, item] }
        earlier = latest.values.select { |item| item.state == "held" && item.serial != serial }.sort_by(&:serial)
                        .map { |item| [item.serial, item.reason.to_s] }
        wakes = WorkerWakes.new(grace: 0)
        turns = case receipt&.reason
                when "peer_turns" then wakes.peer_turns
                when "max_wakes" then wakes.max
                end
        PeerSay.new(status: :received, serial: serial, wake: at_once, receipt: receipt, earlier: earlier, turns: turns)
      end

      # A session source's push, as a push delivery (SessionInbox.deliver
      # :push): the text recorded, then a wake when it asks one (a change
      # with wake, context.wake on, the source not woken lately) as the
      # push WakePolicy decides (an idle-exited session starts; a stopped
      # one never). A failed wake is logged: the push stands.
      # @return [ContextPush]
      def push_delivery(session_id, name, fetched, location, record)
        before = written = asked = nil
        delivered = begin
          SessionInbox.deliver(:push, session_id, state_dir: state_dir!) do
            before, written = record.call
            asked = fetched.wake && before != written.revision && context_wake_allowed?(location, name)
          end
        rescue StandardError => e
          raise unless written

          Log.exception(:context, "context_push_wake_failed", e, sid: session_id, source: name)
          nil
        end
        # Its session file is gone (:gone): the source's folder takes it, as before.
        before, written = record.call if delivered&.refused?
        ContextPush.new(status: :pushed, before: before, revision: written.revision, wake: asked ? delivered&.wake : nil)
      end

      def context_wake_allowed?(location, name)
        return false if Config.get("context.wake") == false

        !context_wake_recent?(location.subscription(name))
      end

      def grants = @grants ||= Grants.new(Grants.path(state_dir: state_dir!))

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
        configured = LiveVersions.configured_web_port
        answer = LiveVersions.web_answering("127.0.0.1", configured, path: Web::Running.path(state_dir: state_dir!),
                                                                     timeout: LOCAL_PROBE_TIMEOUT)
        return LocalWeb.new(ip: nil, port: configured) unless answer

        LocalWeb.new(ip: own_address(answer.info["lan"]), port: answer.port)
      end

      def dir = @state_dir ? { state_dir: @state_dir } : {}

      # The session that continues +id+, or nil. The archive check first: a
      # continued link is always archived, and SessionChain.next_of loads
      # every session.
      def continued_as(id)
        return nil unless ArchiveStore.archived?(session_dir(id))

        SessionChain.next_of(id, state_dir: state_dir!)
      end

      def state_dir! = @state_dir || Session.default_state_dir
      def session_dir(id) = Session.session_dir(id, state_dir: state_dir!)

      def context_wake_recent?(subscription)
        return false unless subscription.wakes_at

        Time.now - Time.iso8601(subscription.wakes_at) < WorkerInbound::CONTEXT_WAKE_WINDOW
      rescue ArgumentError
        false
      end

      def attached_to(target, shadowed: false)
        ContextSources.attached(target.session_id, project_root: target.project_root, project_id: target.project_id,
                                                   state_dir: @state_dir, shadowed: shadowed)
      end

      # The block's post to the session's live worker, again on a 408 (the
      # worker didn't take it in time).
      # The shortest read timeout a cut try gets (#on_worker's within:).
      MIN_TRY = 1.0

      def on_worker(id, within: nil)
        limit = within ? within.to_f.clamp(MIN_TRY, BridgeClient::READ_TIMEOUT.to_f) : BridgeClient::READ_TIMEOUT
        client = WorkerLink.client(id, session_dir: session_dir(id), read_timeout: limit) or return nil
        ends = monotonic + within if within
        reply = nil
        2.times do
          reply = yield client
          break unless reply.status == 408
          break if ends && monotonic + limit > ends
        end
        reply
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
