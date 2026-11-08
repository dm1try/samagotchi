# frozen_string_literal: true

module Samagotchi
  class SessionManager
    # Listing: read-only queries over the saved sessions (the lists, their
    # summary rows, a parent's delegates, a session's replies). Calls the
    # facade's session_owner. Meant to be loaded through samagotchi/session_manager.
    module ListingPart
      # List all sessions, reading status from persisted session.json files.
      # +project_root+: only that project's sessions (nil: every session).
      # +include_archived+: archived sessions too (Session#archived says which).
      def list_sessions(state_dir: nil, sort: "updated_at", order: "desc", limit: nil, offset: 0, project_root: nil,
                        include_archived: false)
        Session.list(state_dir: state_dir || Session.default_state_dir, sort: sort, order: order, limit: limit,
                     offset: offset, project_root: project_root, include_archived: include_archived)
      end

      # Short summaries of sessions, newest first: the picker behind
      # `chi sessions list --live --format json|tsv` (chi note from a script)
      # and the agent's list_sessions tool; both pass the current project as
      # +project_root+ unless asked for every project.
      # @param live [Boolean] only sessions a worker owns now (WorkerLink's
      #   worker_owned?: the owner lock, not the saved status, which a dead
      #   worker leaves at "running"); a session a one-shot (or an older
      #   chi's REPL) owns is left out: it can't take notes
      # @param cwd [String, nil] only sessions in this folder or below it
      # @param project_root [String, nil] only this project's sessions
      #   (Session#project_root)
      # @param limit [Integer, nil] taken after the filters
      # @param include_tests [Boolean] false leaves out test runs
      # @param exclude [String, nil] a session id to leave out (the asker)
      # @param include_archived [Boolean] archived sessions too
      # @return [Array<SessionRow>] see SessionRow for the fields
      def session_rows(live: false, cwd: nil, limit: nil, include_tests: true, exclude: nil, state_dir: nil,
                       project_root: nil, include_archived: false, sort: nil, order: nil)
        sd = state_dir || Session.default_state_dir
        root = cwd && folder_path(cwd)
        roots = {}
        # One registry per listing, built only when a row has a saved context
        # to count: its session's llm_context budget is what ctx_pct counts
        # against (SessionMetrics.saved_context_pct).
        budgets = SessionRow.budgets
        rows = Session.list(state_dir: sd, sort: sort || "updated_at", order: order || "desc", project_root: project_root,
                            include_archived: include_archived).lazy
                      .reject { |s| (!include_tests && s.test_run) || s.id == exclude }
                      .select { |s| root.nil? || in_folder?(s.working_directory, root) }
                      .filter_map do |s|
          dir = Session.session_dir(s.id, state_dir: sd)
          owner = session_owner(s.id, state_dir: sd)
          link = WorkerLink.resolve(dir, unlink: false, owner: owner)
          next if live && !link.worker_owned?

          SessionRow.build(s, session_dir: dir, owner: owner, link: link, roots: roots, budgets: budgets)
        end
        (limit ? rows.first(limit) : rows.to_a)
      end

      # .session_rows as the summaries route's hashes (SessionRow#to_summary_h,
      # its 28 keys in order): chi web's GET /api/sessions/summaries.
      # @return [Array<Hash>]
      def session_summaries(**filters) = session_rows(**filters).map(&:to_summary_h)

      # The sessions delegated by +parent_id+ (the `delegate` tool), newest
      # first, as .session_summaries rows. A running one (busy) counts against
      # session.max_children. Archived ones too.
      def children_of(parent_id, state_dir: nil)
        return [] if parent_id.to_s.empty?

        session_summaries(state_dir: state_dir, include_tests: true, include_archived: true)
          .select { |s| s[:parent_id] == parent_id.to_s }
      end

      # Children, their children, …: a delegated session doesn't delegate
      # further today, a plugin's fork may. The walk doesn't enter +except+.
      def descendant_ids(id, state_dir, except: [])
        seen = [id]
        queue = [id]
        until queue.empty?
          children_of(queue.shift, state_dir: state_dir).each do |child|
            next if seen.include?(child[:id]) || except.include?(child[:id])

            seen << child[:id]
            queue << child[:id]
          end
        end
        seen.drop(1)
      end

      private def folder_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      private def in_folder?(dir, root)
        dir = dir.to_s.chomp("/")
        root = root.chomp("/")
        dir == root || dir.start_with?("#{root}/")
      end

      # Read any new output files from a session directory.
      # Optionally filters to only files newer than `since_time`.
      def read_responses(session_id, since_time: nil, state_dir: nil)
        SessionInbox.read_outputs(Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir),
                                  since_time: since_time)
      end

      def stopped_on_disk?(session_id, state_dir:)
        Session.load(session_id, state_dir: state_dir).status == Session::STATUS_STOPPED
      rescue ArgumentError
        false
      end
    end

    extend ListingPart
  end
end
