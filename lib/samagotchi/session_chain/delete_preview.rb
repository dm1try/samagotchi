# frozen_string_literal: true

require_relative "delete"

module Samagotchi
  module SessionChain
    module Delete
      # What the web's delete sheet shows for any session (GET
      # /api/sessions/:id/delete_plan): the same LinkPlan and ChainPlan the
      # delete runs, and the refusals the delete's own checks raise now
      # (check_link!, check_chain!, the continue holds, a one-turn run), with
      # each choice's delegates, running tasks and workers. Made from one
      # shared session listing each time the sheet opens. It read-only checks
      # each link's continue lock (a session in no chain too); besides that,
      # only the listing's own repair of an interrupted continue writes. A
      # stale preview is fine: the delete builds its plan again and refuses as
      # it does.
      module Preview
        module_function

        # @return [Hash] {chained: false, session_id, link: {...}} for a
        #   session in no chain (an older page reads only chained), else
        #   {chained: true, session_id, position, size, cut_off, link: {...},
        #   chain: {...}}; each refusal {reason, message, schedule_id, ids,
        #   stoppable} or nil. Each choice also has +delegates+ ({delete:
        #   [ids], leave: [{id, running}]}: +running+ false for a stopped
        #   session left under a running delegate), +tasks+ (RunningTasks.of
        #   the ids it deletes, the wire form) and +worker+ (#link_worker; a
        #   chain's {idle: n, turn: n} over its links). No titles: the page
        #   names each id from its own list.
        # @param state_dir [String, nil] nil: Session.default_state_dir (chi
        #   web's, as SessionManager's methods take it)
        def call(id, state_dir:)
          state_dir ||= Session.default_state_dir
          links = Links.new(state_dir: state_dir)
          rows = SessionManager.session_rows(state_dir: state_dir, include_tests: true, include_archived: true)
          this = Delete.link_plan(id, state_dir: state_dir, links: links, rows: rows)
          return { chained: false, session_id: id, link: link_json(this, links, nil, 0, state_dir, rows: rows) } unless Delete.chained?(id, links)

          whole = Delete.chain_plan(id, state_dir: state_dir, links: links, rows: rows)
          at = whole.links.index(id) || 0
          { chained: true, session_id: id, position: at + 1, size: whole.links.size, cut_off: whole.cut_off,
            link: link_json(this, links, whole, at, state_dir, rows: rows), chain: chain_json(whole, state_dir) }
        end

        # +whole+ nil: a session in no chain (no link before or after it).
        def link_json(plan, links, whole, at, state_dir, rows:)
          { digest: Delete.digest(plan), previous_id: plan.previous, moved: moved_count(plan, state_dir, rows: rows), notes: plan.notes, unarchived: plan.revive.size,
            deletes: plan.delegates.delete.size, left_running: plan.delegates.leave.size,
            earlier: at, next_id: whole && links.next_of(plan.id), later: whole ? whole.links.size - at - 1 : 0,
            delegates: delegates_json(plan.delegates.delete, plan.delegates.leave, state_dir),
            tasks: tasks_json([*plan.delegates.delete, plan.id], state_dir), worker: link_worker(plan.id, state_dir),
            refusal: refusal(state_dir) { link_checks(plan, state_dir) } }
        end

        # The ids that go, and each one left with whether it runs itself (a
        # left running delegate's stopped descendants stay with it).
        def delegates_json(delete, leave, state_dir)
          { delete: delete, leave: leave.map { |sid| { id: sid, running: SessionManager::DELEGATES.running?(sid, state_dir) } } }
        end

        def tasks_json(ids, state_dir) = SessionManager::RunningTasks.of(ids, state_dir: state_dir).to_wire

        # "turn" when a worker owns +id+ and its saved status is running,
        # "idle" when a worker owns it or is being started for it, else nil.
        def link_worker(id, state_dir)
          presence = WorkerPresence.read(id, state_dir: state_dir, owner: SessionManager.session_owner(id, state_dir: state_dir))
          return nil unless presence.owned? || presence.starting?
          return "idle" unless presence.owned?

          Session.load(id, state_dir: state_dir).status == Session::STATUS_RUNNING ? "turn" : "idle"
        rescue Session::NotFound, ArgumentError, SystemCallError
          "idle"
        end

        # The sessions that go back with the undo: each moved delegate and
        # its own subtree (they come back with it).
        def moved_count(plan, state_dir, rows:)
          plan.moved.sum { |child| 1 + SessionManager.descendant_ids(child, state_dir, rows: rows).size }
        end

        def chain_json(plan, state_dir)
          delete = plan.delegates.values.flat_map(&:delete)
          leave = plan.delegates.values.flat_map(&:leave).uniq
          workers = plan.links.map { |link| link_worker(link, state_dir) }
          { digest: Delete.digest(plan), links: plan.links.size, deletes: plan.delegates.values.sum { |d| d.delete.size },
            left_running: plan.delegates.values.sum { |d| d.leave.size },
            delegates: delegates_json(delete, leave, state_dir), tasks: tasks_json([*plan.links, *delete], state_dir),
            worker: { idle: workers.count("idle"), turn: workers.count("turn") },
            refusal: refusal(state_dir) { chain_checks(plan, state_dir) } }
        end

        # The link delete's refusals in its order: a continue of it (or of
        # the previous link it undoes), a one-turn run, then check_link!.
        def link_checks(plan, state_dir)
          [plan.id, plan.previous].compact.each { |sid| refuse_continuing!(sid, state_dir) }
          tui!(plan.id, state_dir)
          Delete.check_link!(plan, state_dir)
        end

        # The web always stops the links' workers (force), so a worker is no
        # refusal here.
        def chain_checks(plan, state_dir)
          Delete.check_chain!(plan, state_dir, stop: true)
          plan.links.each { |sid| refuse_continuing!(sid, state_dir) }
        end

        def refuse_continuing!(id, state_dir)
          raise SessionManager::DeleteRefused.new(id, :continuing) if ContinueIntent.lock_held?(id, state_dir: state_dir)
        end

        def tui!(id, state_dir)
          presence = WorkerPresence.read(id, state_dir: state_dir, owner: SessionManager.session_owner(id, state_dir: state_dir))
          raise SessionManager::OwnedByTUI, id if presence.tui_owned?
        end

        # The block's refusal as the sheet reads it, nil when there is none.
        # +stoppable+: a moved delegate that can't go back is on an older
        # chi's worker the page can stop (Delete.stoppable?).
        def refusal(state_dir)
          yield
          nil
        rescue SessionManager::OwnedByTUI => e
          { reason: "owned_by_tui", message: e.message, ids: [e.session_id] }
        rescue SessionManager::DeleteRefused => e
          { reason: e.reason.to_s, message: e.message, schedule_id: e.schedule_id, ids: e.ids,
            stoppable: e.reason == :delegate_unmovable ? Delete.stoppable?(e.ids, state_dir) : nil }.compact
        end
      end
    end
  end
end
