# frozen_string_literal: true

require_relative "../session"
require_relative "../recap_store"
require_relative "../archive_store"
require_relative "../session_metrics"
require_relative "../llm_context_strategy"
require_relative "../host_registry"
require_relative "../bridge_client"
require_relative "../worker_sidecar"
require_relative "../bridge/pending_card"

module Samagotchi
  module Web
    # A session as the page's cards and list see it: the saved session's
    # fields with its live owner applied. Built the same way wherever a
    # session is answered (GET /api/sessions, the session view, the session
    # hub's events), so every path agrees on status, owner and bridge_up.
    module SessionSummary
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
        used = Array(session.used_memory_names)
        up = bridge_up?(session_dir, owner)
        sidecar = up ? WorkerSidecar.read(session_dir) : nil
        saved = SessionMetrics.saved_summary(session_dir, budget_tokens: budget_resolver(session, registry))
        {
          id: session.id,
          status: status,
          mode: session.mode,
          model_name: session.model_name,
          working_directory: session.working_directory,
          created_at: session.created_at,
          updated_at: session.updated_at,
          last_prompt: session.last_prompt,
          short_id: session.id.to_s[0, 8],
          test_run: !!session.test_run,
          used_memory_names: used,
          # The session's --memory and --mute lists (info-bar tooltip).
          preloaded_memory_names: Array(session.preloaded_memory_names),
          muted_memory_names: Array(session.muted_memory_names),
          # The model notes its prompt carried (the info bar's notes chip).
          prompt_notes: Array(session.prompt_notes).map(&:to_h),
          # The session that delegated this one (the `delegate` tool), else nil.
          parent_id: session.parent_id,
          # Started by the delegate tool (Session#delegate?); a fork has a
          # parent_id too but isn't one. The parent's children chip counts
          # delegates only, as the TUI's segment and /children do.
          delegate: session.delegate?,
          first_preview: first_preview_for(session),
          owner: owner&.kind,
          # The saved recap's first sentence, for the session card.
          recap: RecapStore.preview(session_dir),
          # How full the context was after the last turn (%), or nil, and
          # the session's token sums and cost (the card's ctx tooltip), from
          # one read of analytics.json.
          ctx_pct: saved&.ctx_pct&.round(1),
          tokens: saved&.tokens,
          # The memory indexes its prompt held (the card's ctx tooltip).
          memory_index: saved&.memory_index,
          # Hidden from the strip and the list unless "include archived".
          archived: ArchiveStore.archived?(session_dir),
          project_root: session.project_root(cache: root_cache),
          # A worker is reachable: its Bridge sidecar is there and the
          # owner lock is held. A sidecar a dead worker left is not up.
          bridge_up: up,
          # The chi the live worker runs and what it can do (its sidecar;
          # nil and [] without one): the page's stale-worker badge.
          worker_version: sidecar&.version,
          worker_features: sidecar ? sidecar.features : [],
          # For the tab's notifications (notify.js): an open question, the
          # running turn's open card with actions, and how the last turn
          # ended. A question saved by a worker that died is not open, nor a
          # chi REPL's (SessionManager.worker_live?'s rule: only a worker shares it).
          pending_question: session.waiting_question(live: !!owner&.worker?),
          pending_card: up ? Bridge::PendingCard.read(session_dir) : nil,
          last_turn: session.last_turn
        }
      end

      # The budget resolver SessionMetrics.saved_summary takes: a callable,
      # so the session's llm_context budget (config + the registry's index,
      # no network) is resolved only for a session that has a saved context
      # to count. One registry per caller (the hub) or one built here.
      def budget_resolver(session, registry)
        -> { LLMContextStrategy.session_budget(session, registry: registry ||= HostRegistry.new) }
      end
      private_class_method :budget_resolver

      # status is turn state (idle/running). The live worker's snapshot is the
      # truth; on disk, a "running" with no live owner was left by a worker
      # that died mid-turn.
      def displayed_status(session, snapshot = nil, owner:)
        return snapshot["status"] if snapshot.is_a?(Hash) && snapshot["status"]
        return session.status unless session.status == Session::STATUS_RUNNING

        owner ? session.status : Session::STATUS_IDLE
      end

      # @return [Boolean] the sidecar file is there and the session has a
      #   live owner (the file alone says nothing: the worker may be gone).
      #   The owner lock, not WorkerSidecar.live's port probe: a list builds
      #   this for every session, and the lock costs no connect.
      def bridge_up?(session_dir, owner)
        !owner.nil? && File.file?(WorkerSidecar.path(session_dir))
      rescue StandardError
        false
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
