# frozen_string_literal: true

require_relative "../session"
require_relative "../recap_store"
require_relative "../bridge_client"

module Samagotchi
  module Web
    # A session as the page's cards and list see it: the saved session's
    # fields with its live owner applied. Built the same way wherever a
    # session is answered (GET /api/sessions, the session view, the session
    # hub's events), so every path agrees on status, owner and bridge_up.
    module SessionSummary
      module_function

      # @param session [Session] a saved session (messages may be empty)
      # @param owner [Hash, nil] SessionManager.session_owner's answer; its
      #   kind is shown as `owner`
      # @param session_dir [String] the session's folder (recap.json, bridge.json)
      # @param status [String] the turn state to show; by default
      #   .displayed_status of the session and its owner
      # @param root_cache [Hash, nil] ProjectScope.root_for's cache, shared
      #   across one listing (a session saved before project_root existed
      #   looks its project up)
      # @return [Hash] symbol keys
      def build(session, owner:, session_dir:, status: displayed_status(session, owner: owner), root_cache: nil)
        used = session.respond_to?(:used_memory_names) ? Array(session.used_memory_names) : []
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
          preloaded_memory_names: session.respond_to?(:preloaded_memory_names) ? Array(session.preloaded_memory_names) : [],
          muted_memory_names: session.respond_to?(:muted_memory_names) ? Array(session.muted_memory_names) : [],
          first_preview: first_preview_for(session),
          owner: owner&.fetch("kind", nil),
          # The saved recap's first sentence, for the session card.
          recap: RecapStore.preview(session_dir),
          project_root: session.project_root(cache: root_cache),
          # A worker is reachable: its Bridge sidecar is there and the
          # owner lock is held. A sidecar a dead worker left is not up.
          bridge_up: bridge_up?(session_dir, owner)
        }
      end

      # status is turn state (idle/running). The live worker's snapshot is the
      # truth; on disk, a "running" with no live owner was left by a worker
      # that died mid-turn.
      def displayed_status(session, snapshot = nil, owner:)
        return snapshot["status"] if snapshot.is_a?(Hash) && snapshot["status"]
        return session.status unless session.status == Session::STATUS_RUNNING

        owner ? session.status : Session::STATUS_IDLE
      end

      # @return [Boolean] the sidecar file is there and the session has a
      #   live owner (the file alone says nothing: the worker may be gone)
      def bridge_up?(session_dir, owner)
        !owner.nil? && File.file?(File.join(session_dir, BridgeClient::SIDECAR_FILE))
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
