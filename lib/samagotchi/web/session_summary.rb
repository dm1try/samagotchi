# frozen_string_literal: true

require_relative "../session"
require_relative "../steer"
require_relative "../participants"
require_relative "../verify_fresh"
require_relative "../recap_store"
require_relative "../archive_store"
require_relative "../session_metrics"
require_relative "../effective_model"
require_relative "../host_registry"
require_relative "../bridge_client"
require_relative "../worker_link"
require_relative "../session_row"
require_relative "../bridge/pending_card"

module Samagotchi
  module Web
    # A session as the page's cards and list see it: the saved session's
    # fields with its live owner applied. Built the same way wherever a
    # session is answered (GET /api/sessions, the session view, the session
    # hub's events), so every path agrees on status, owner and bridge_up.
    module SessionSummary
      # The page's keys, in the order it has always had them (a hub event
      # compares with ==, a 0.156 page reads them by name).
      WEB_KEYS = %i[id status mode model_name working_directory created_at updated_at last_prompt short_id test_run
                    used_memory_names preloaded_memory_names muted_memory_names prompt_notes parent_id delegate
                    continues review first_preview title owner recap auto_title ctx_pct tokens memory_index side
                    archived project_root bridge_up worker_version worker_features pending_question pending_card
                    last_turn verdicts verify_fresh last_verdict].freeze

      module_function

      # @param session [Session] a saved session (messages may be empty)
      # @param owner [OwnerLock::Owner, nil] SessionManager.session_owner's; its
      #   kind is shown as `owner`
      # @param session_dir [String] the session's folder (recap.json, bridge.json)
      # @param status [String] the turn state to show; by default
      #   .displayed_status of the session and its owner
      # @param root_cache [Hash, nil] ProjectScope.root_for's cache, shared
      #   across one listing (a session saved before project_root existed
      #   looks its project up)
      # @param registry [HostRegistry, nil] the hosts to resolve the
      #   session's llm_context budget against (its ctx_pct counts against
      #   the smaller of that budget and the window, as the live meter
      #   does). nil: one is built here; a caller that builds many summaries
      #   (the session hub) keeps one and passes it.
      # @return [Hash] symbol keys
      def build(session, owner:, session_dir:, status: displayed_status(session, owner: owner), root_cache: nil,
                registry: nil)
        link = WorkerLink.resolve(session_dir, unlink: false, owner: owner)
        up = link.live?
        sidecar = up ? link.sidecar : nil
        saved = SessionMetrics.saved_summary(session_dir, budget_tokens: budget_resolver(session, registry))
        # The facts every list shares (SessionRow), from this one link,
        # analytics and recap read.
        row = SessionRow.build(session, session_dir: session_dir, owner: owner, link: link, roots: root_cache || {},
                                        saved: saved, card: RecapStore.card(session_dir))
        values = {
          id: row.id,
          status: status,
          mode: session.mode,
          model_name: session.model_name,
          working_directory: row.cwd,
          created_at: session.created_at,
          updated_at: row.updated_at,
          last_prompt: session.last_prompt,
          short_id: row.short_id,
          test_run: !!row.test_run,
          used_memory_names: Array(session.used_memory_names),
          # The session's --memory and --mute lists (info-bar tooltip).
          preloaded_memory_names: Array(session.preloaded_memory_names),
          muted_memory_names: Array(session.muted_memory_names),
          # The model notes its prompt carried (the info bar's notes chip).
          prompt_notes: Array(session.prompt_notes).map(&:to_h),
          # The session that delegated this one (the `delegate` tool), else nil.
          parent_id: row.parent_id,
          # Started by the delegate tool (Session#delegate?); a fork has a
          # parent_id too but isn't one. The parent's children chip counts
          # delegates only, as the TUI's segment and /children do.
          delegate: row.delegate,
          # The session this one continues (the previous link of its
          # chain), else nil: the lists draw chains from it.
          continues: row.continues,
          # A review session's {subjects, from} (SessionReview), else nil:
          # the session bar offers Start review on the others.
          review: session.review&.to_file,
          first_preview: first_preview_for(session),
          # The session's own name (/title), else nil: the pages show it in
          # place of the first message.
          title: row.title,
          owner: row.owner,
          # The saved recap's first sentence, for the session card, and the
          # auto title its reply led with (RecapTitle), else nil: an untitled
          # session's name on the pages and its pushes (never in a model
          # request).
          recap: row.recap,
          auto_title: row.auto_title,
          # How full the context was after the last turn (%), or nil, and
          # the session's token sums and cost (the card's ctx tooltip), from
          # one read of analytics.json.
          ctx_pct: row.ctx_pct,
          tokens: saved&.tokens,
          # The memory indexes its prompt held (the card's ctx tooltip).
          memory_index: saved&.memory_index,
          # Its side requests, apart from the tokens (the tooltip's own line).
          side: saved&.side,
          # Hidden from the strip and the list unless the all view's "archived" toggle is on.
          archived: row.archived,
          project_root: row.project,
          # A worker is reachable: WorkerLink answers Live (the lock held by
          # a worker whose sidecar names its pid). A sidecar a dead worker
          # left is not up.
          bridge_up: up,
          # The chi the live worker runs and what it can do (its sidecar;
          # nil and [] without one): the page's stale-worker badge.
          worker_version: sidecar&.version,
          worker_features: sidecar ? sidecar.features : [],
          # For the tab's notifications (notify.js): an open question, the
          # running turn's open card with actions, and how the last turn
          # ended. A question saved by a worker that died is not open, nor a
          # one-turn chi run's (only a worker shares it): the row's live.
          pending_question: session.waiting_question(live: row.live),
          pending_card: up ? Bridge::PendingCard.read(session_dir) : nil,
          last_turn: session.last_turn&.to_file,
          # Its Verify verdicts, the fresh ones its worker hasn't taken yet
          # too (VerifyFresh.verdicts_of), and the fresh checks running now
          # ({of, child_id}: the card's "verifying fresh" and its link).
          verdicts: VerifyFresh.verdicts_of(session, session_dir),
          verify_fresh: VerifyFresh.running(session.id, state_dir: File.dirname(session_dir))
                                   .map { |entry| { of: entry[:of], child_id: entry[:child_id] } },
          last_verdict: last_verdict(session, session_dir)
        }
        WEB_KEYS.to_h { |key| [key, values.fetch(key)] }
      end

      def last_verdict(session, session_dir)
        raw = Array(session.verdicts).last
        return unless raw.is_a?(Hash)

        verdict = raw.to_h { |key, value| [key.to_sym, value] }
        author = verdict[:by]
        return verdict unless Steer.participant_author?(author)

        participant = Participants.read(session.id, state_dir: File.dirname(session_dir))
                                  .find { |entry| entry.id == Steer.participant_id(author) }
        participant ? verdict.merge(by_name: participant.name) : verdict
      end
      private_class_method :last_verdict

      # The budget resolver SessionMetrics.saved_summary takes: a callable,
      # so the session's llm_context budget (config + the registry's index,
      # no network) is resolved only for a session that has a saved context
      # to count. One registry per caller (the hub) or one built here.
      def budget_resolver(session, registry)
        -> { EffectiveModel.session_budget(session, registry: registry ||= HostRegistry.current) }
      end
      private_class_method :budget_resolver

      # status is turn state (idle/running). The live worker's snapshot is the
      # truth; on disk, Session#displayed_status (a "running" with no live
      # owner was left by a worker that died mid-turn).
      def displayed_status(session, snapshot = nil, owner:)
        return snapshot["status"] if snapshot.is_a?(Hash) && snapshot["status"]

        session.displayed_status(owner: owner)
      end

      def first_preview_for(session)
        raw = session.first_preview || session.last_prompt || ""
        norm = raw.to_s.gsub(/\s+/, " ").strip
        return "" if norm.empty?

        norm.length > 80 ? "#{norm[0, 80]}…" : norm
      rescue StandardError
        ""
      end
    end
  end
end
