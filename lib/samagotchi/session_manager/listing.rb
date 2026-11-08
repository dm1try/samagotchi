# frozen_string_literal: true

module Samagotchi
  class SessionManager
    SUMMARY_DESC_LIMIT = 60

    SUMMARY_PREVIEW_LIMIT = 120

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
      # @param live [Boolean] only sessions a worker owns now (the owner lock,
      #   not the saved status, which a dead worker leaves at "running"); a
      #   session a one-shot (or an older chi's REPL) owns is left out: it
      #   can't take notes
      # @param cwd [String, nil] only sessions in this folder or below it
      # @param project_root [String, nil] only this project's sessions
      #   (Session#project_root)
      # @param limit [Integer, nil] taken after the filters
      # @param include_tests [Boolean] false leaves out test runs
      # @param exclude [String, nil] a session id to leave out (the asker)
      # @param include_archived [Boolean] archived sessions too
      # @return [Array<Hash>] {id:, short_id:, desc:, preview:, cwd:, project:,
      #   updated_at:, status:, saved_status:, live:, busy:, owner:, recap:, auto_title:, parent_id:,
      #   parent_short_id:, continues:, continues_short_id:, delegate:, archived:, scratch:, test_run:, waiting:,
      #   waiting_id:, stopped_by:}; status = Session#displayed_status (a dead
      #   worker's "running" is idle, as chi web shows it), saved_status = the
      #   file's (a "running" with no owner yet is also a worker on its way:
      #   Tools::Delegate.running?), busy =
      #   live with a turn running, delegate = started by the delegate tool
      #   (Session#delegate?; a fork has a parent_id but isn't one), continues = the session it continues (the
      #   previous link of its chain, Session#continues), recap = the saved recap's first sentence, auto_title =
      #   the auto title its reply led with (RecapTitle) or nil, project =
      #   Session#project_root, waiting = the kind of question it waits on
      #   ("question", "approval", "hook"; Session#waiting_question) or nil,
      #   waiting_id = that question's id or nil, relayed_to = the parent
      #   whose card it waits in too (the approval relay), its short id, or nil,
      #   stopped_by = the hook that stopped the last turn (Session#stopped_by)
      def session_summaries(live: false, cwd: nil, limit: nil, include_tests: true, exclude: nil, state_dir: nil,
                            project_root: nil, include_archived: false, sort: nil, order: nil)
        sd = state_dir || Session.default_state_dir
        root = cwd && folder_path(cwd)
        roots = {}
        # One registry per listing, built only when a row has a saved context
        # to count: its session's llm_context budget is what ctx_pct counts
        # against (SessionMetrics.saved_context_pct).
        budgets = listing_budgets
        summaries = Session.list(state_dir: sd, sort: sort || "updated_at", order: order || "desc", project_root: project_root,
                                 include_archived: include_archived).lazy
                           .reject { |s| (!include_tests && s.test_run) || s.id == exclude }
                           .select { |s| root.nil? || in_folder?(s.working_directory, root) }
                           .filter_map do |s|
          owner = session_owner(s.id, state_dir: sd)
          owned = !!owner&.worker?
          next if live && !owned

          { id: s.id, short_id: s.id[0, 8], desc: summary_desc(s), preview: summary_preview(s), title: s.title, cwd: s.working_directory,
            project: s.project_root(cache: roots), updated_at: s.updated_at, status: s.displayed_status(owner: owner), saved_status: s.status, live: owned, busy: owned && s.status == Session::STATUS_RUNNING,
            owner: owner&.kind, **recap_fields(Session.session_dir(s.id, state_dir: sd)),
            ctx_pct: SessionMetrics.saved_context_pct(Session.session_dir(s.id, state_dir: sd),
                                                      budget_tokens: -> { budgets.call(s) })&.round(1),
            parent_id: s.parent_id, parent_short_id: s.parent_id&.[](0, 8), continues: s.continues,
            continues_short_id: s.continues&.[](0, 8), delegate: s.delegate?, archived: s.archived,
            scratch: s.scratch, test_run: s.test_run, stopped_by: s.stopped_by }.merge(waiting_fields(s.waiting_question(live: owned)))
        end
        (limit ? summaries.first(limit) : summaries.to_a)
      end

      # waiting: the question's kind, waiting_id: its id (what chi answer
      # --question takes); both nil with none.
      private def waiting_fields(waiting)
        { waiting: waiting&.dig(:kind), waiting_id: waiting&.dig(:id), relayed_to: waiting&.dig(:relayed_to) }
      end

      # One HostRegistry for a whole listing, built on the first row that
      # needs it (a saved context to count) and kept for the rest: resolving a
      # session's llm_context budget reads config.yml (mtime-cached), so not
      # one registry per row.
      # @return [#call] (session) -> the session's budget in tokens or nil
      private def listing_budgets
        registry = nil
        ->(session) { LLMContextStrategy.session_budget(session, registry: registry ||= HostRegistry.new) }
      end

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

      # "<cwd basename> · <last prompt, or the first preview>", one line.
      private def summary_desc(session)
        desc = [File.basename(session.working_directory.to_s), summary_text(session)].reject(&:empty?).join(" · ")
        cut(desc, SUMMARY_DESC_LIMIT)
      end

      # A session row's recap: and auto_title: (RecapStore.card, one read).
      private def recap_fields(session_dir)
        card = RecapStore.card(session_dir)
        { recap: card.preview, auto_title: card.title }
      end

      private def summary_preview(session)
        cut(summary_text(session), SUMMARY_PREVIEW_LIMIT)
      end

      # A session as one line of text for the lists: its title (/title), else
      # its last prompt, else the first message it was started with (a session
      # command like `/model x`, or a first turn not saved yet).
      def summary_text(session)
        return one_line(session.title) unless session.title.to_s.strip.empty?

        one_line(session.last_prompt.to_s.strip.empty? ? session.first_preview.to_s : session.last_prompt.to_s)
      end

      # A prompt as one line for a session list: whitespace collapsed, and a
      # quoted or annotated message (ContextQuote, the web's annotations)
      # without its "> " markers, so the words show.
      def one_line(text)
        text.to_s.gsub(/^[ \t]*(?:>[ \t]?)+/, "").gsub(/\s+/, " ").strip
      end

      private def cut(text, limit)
        text.length > limit ? "#{text[0, limit - 1]}…" : text
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
