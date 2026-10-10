# frozen_string_literal: true

module Samagotchi
  # The views of an Engine its peers get: the kernel's tools
  # (Engine#initialize sets @kernel.peers) and a delegate's approval relay
  # (Engine#relay_peer).
  class Engine
    # The kernel's Tools::Peers, following the current session. cancelled?
    # is the running turn's cancel, for a tool that waits (delegate_result):
    # the controller is set from another thread and a tool gets no other
    # way to see it.
    PeerView = Struct.new(:engine) do
      def session_id = engine.session&.id
      def cwd = engine.session&.working_directory
      def project_root = engine.session&.project_root
      def state_dir = engine.peer_state_dir
      def cancelled? = !!engine.active_cancel_controller&.cancelled?
      def relay = engine.relay_peer
      def model_ref = engine.effective_model_ref
      def thinking = engine.thinking_override
    end

    # What the approval relay needs from the parent's Engine (Peers#relay):
    # its own question flow, which every UI attached to it answers.
    RelayPeer = Struct.new(:engine) do
      def open_question(fields, watch: nil) = engine.open_question(fields, watch: watch)
      def interface = engine.interface
      def relay_desk = engine.relay_desk
    end
  end
end
