# frozen_string_literal: true

require_relative "../worker_presence"

module Samagotchi
  class SessionManager
    # D7, the rule a user's delete applies to a session's delegates (today
    # the chain deletes: SessionChain::Delete.link_plan and .chain_plan): a
    # delegate is running when a worker owns it or is being started for it
    # (a one-turn chi run too, which can't be stopped from here). A saved
    # status running with no worker is a crashed run: it goes. A running one
    # is left with its whole subtree; every other node under the session (no
    # running node between it and the session) is deleted.
    #
    # One listing per plan: the rows are read once (.session_rows, archived
    # and test runs too, as .children_of reads them) and the tree is walked
    # in memory.
    class DelegateRule
      # What the rule does with a session's delegates: +delete+ (deepest
      # first, before the session) and +leave+ (running, with their whole
      # subtrees: they go on without a parent, their files untouched).
      Plan = Data.define(:delete, :leave)

      # @param except [Array<String>] the session's children left out with
      #   their subtrees (the ones a chain link's undo gives back)
      # @return [Plan]
      def plan(id, state_dir:, except: [])
        children = children_by_parent(state_dir)
        delete = []
        leave = []
        queue = [id]
        until queue.empty?
          children.fetch(queue.shift, []).each do |child|
            next if child == id || except.include?(child) || delete.include?(child) || leave.include?(child)

            if running?(child, state_dir)
              leave.concat([child, *descendants(child, children)] - leave)
            else
              delete << child
              queue << child
            end
          end
        end
        Plan.new(delete: delete.reverse, leave: leave)
      end

      # Whether the rule counts +id+ as running: a worker owns it or is being
      # started for it. The delete sheet's preview reads it per left node.
      def running?(id, state_dir)
        presence = WorkerPresence.read(id, state_dir: state_dir,
                                           owner: SessionManager.session_owner(id, state_dir: state_dir))
        presence.owned? || presence.starting?
      end

      private

      # Every session's children ids, newest first (.children_of's order),
      # from one .session_rows.
      # @return [Hash{String => Array<String>}]
      def children_by_parent(state_dir)
        SessionManager.session_rows(state_dir: state_dir, include_tests: true, include_archived: true)
                      .each_with_object({}) do |row, by_parent|
          (by_parent[row.parent_id] ||= []) << row.id unless row.parent_id.to_s.empty?
        end
      end

      # .descendant_ids over the same rows.
      def descendants(id, children)
        seen = [id]
        queue = [id]
        until queue.empty?
          children.fetch(queue.shift, []).each do |child|
            next if seen.include?(child)

            seen << child
            queue << child
          end
        end
        seen.drop(1)
      end
    end

    # The one DelegateRule every user's delete uses.
    DELEGATES = DelegateRule.new.freeze
  end
end
