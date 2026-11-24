# frozen_string_literal: true

require_relative "objectives"

module Samagotchi
  # The views of an Engine its peers get: the kernel's tools
  # (KernelLoop::Services#peers, Engine#wire_kernel) and a delegate's approval relay
  # (Engine#relay_peer).
  class Engine
    # The running turn's id as other threads see it (TurnState), nil
    # between turns: what PeerView#turn_id reads.
    def running_turn_id = @turn_state.context&.id

    # The kernel's Tools::Peers, following the current session. cancelled?
    # is the running turn's cancel, for a tool that waits (delegate_result):
    # the controller is set from another thread and a tool gets no other
    # way to see it. input_waiting? is whether a person's message waits for
    # the running turn's next boundary (task_wait and the delegate tools' waits
    # return on it, execute hands its command over early).
    PeerView = Struct.new(:engine) do
      def session_id = engine.session&.id
      # The running turn's id (ask_session's request_id), nil between turns.
      def turn_id = engine.running_turn_id
      def cwd = engine.session&.working_directory
      def project_root = engine.session&.project_root
      def project_id = engine.session&.project_id
      def state_dir = engine.peer_state_dir
      def cancelled? = !!engine.active_cancel_controller&.cancelled?
      def cancel_reason = engine.active_cancel_controller&.reason
      def input_waiting? = engine.input_waiting?
      def relay = engine.relay_peer
      def model_ref = engine.effective_model_ref
      def thinking = engine.thinking_override
      def reasoning_history = engine.reasoning_history_override
      # The kits a delegate may start its child on (Engine#toolkit_kits).
      def toolkit_names = engine.toolkit_kits.keys

      # The session's objectives now (the objectives tool), nil outside one.
      def objectives
        session = engine.session
        session && Objectives.current(session.id, session.messages, state_dir: engine.peer_state_dir)
      end

      # A proposed change: its card shows at the turn's end (Engine#propose_objective).
      def propose_objective(proposal) = engine.propose_objective(proposal)
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
