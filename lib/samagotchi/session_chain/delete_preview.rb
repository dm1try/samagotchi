# frozen_string_literal: true

require_relative "delete"

module Samagotchi
  module SessionChain
    module Delete
      # What the web's delete sheet shows for a chained session (GET
      # /api/sessions/:id/delete_plan): the same LinkPlan and ChainPlan the
      # delete runs, and the refusals the delete's own checks raise now
      # (check_link!, check_chain!, the continue holds, a one-turn run). Made
      # from one listing each time the sheet opens. It takes and releases
      # each link's continue lock (shared, as the delete does), creating its
      # empty file where there was none; it writes nothing else. A stale preview is fine:
      # the delete builds its plan again and refuses as it does.
      module Preview
        module_function

        # @return [Hash] {chained: false} for a session in no chain, else
        #   {chained: true, session_id, position, size, cut_off, link: {...},
        #   chain: {...}}; each refusal {reason, message, schedule_id, ids,
        #   stoppable} or nil
        # @param state_dir [String, nil] nil: Session.default_state_dir (chi
        #   web's, as SessionManager's methods take it)
        def call(id, state_dir:)
          state_dir ||= Session.default_state_dir
          links = Links.new(state_dir: state_dir)
          return { chained: false, session_id: id } unless Delete.chained?(id, links)

          this = Delete.link_plan(id, state_dir: state_dir, links: links)
          whole = Delete.chain_plan(id, state_dir: state_dir, links: links)
          at = whole.links.index(id) || 0
          { chained: true, session_id: id, position: at + 1, size: whole.links.size, cut_off: whole.cut_off,
            link: link_json(this, links, whole, at, state_dir), chain: chain_json(whole, state_dir) }
        end

        def link_json(plan, links, whole, at, state_dir)
          { previous_id: plan.previous, moved: moved_count(plan, state_dir), notes: plan.notes, unarchived: plan.revive.size,
            deletes: plan.delegates.delete.size, left_running: plan.delegates.leave.size,
            earlier: at, next_id: links.next_of(plan.id), later: whole.links.size - at - 1,
            refusal: refusal(state_dir) { link_checks(plan, state_dir) } }
        end

        # The sessions that go back with the undo: each moved delegate and
        # its own subtree (they come back with it).
        def moved_count(plan, state_dir)
          plan.moved.sum { |child| 1 + SessionManager.descendant_ids(child, state_dir).size }
        end

        def chain_json(plan, state_dir)
          { links: plan.links.size, deletes: plan.delegates.values.sum { |d| d.delete.size },
            left_running: plan.delegates.values.sum { |d| d.leave.size },
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
          free = ContinueIntent.hold(id, state_dir: state_dir) { |held| held }
          raise SessionManager::DeleteRefused.new(id, :continuing) unless free
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
