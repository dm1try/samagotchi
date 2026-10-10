# frozen_string_literal: true

module Samagotchi
  module Tools
    # What list_sessions, send_note and the delegate tools know about the
    # asking session: its id (left out of the list, the note's sender), its
    # folder, where sessions live, and whether the running turn was
    # canceled (a waiting tool returns on it), and the question flow a
    # delegate's approval is relayed through (relay: nil when this session
    # can't host one), and the model the session runs on (model_ref: the
    # resolved ref, live after /model), and the session's own thinking level
    # (thinking: nil without one). Engine hands KernelLoop one that follows its current
    # session (Engine::PeerView); this plain one is for specs and a kernel
    # without an Engine.
    Peers = Struct.new(:session_id, :cwd, :state_dir, :cancelled, :relay, :model_ref, :thinking, keyword_init: true) do
      # @return [Boolean] the turn was canceled (:cancelled is a proc or a value)
      def cancelled?
        cancelled.respond_to?(:call) ? !!cancelled.call : !!cancelled
      end
    end
  end
end
