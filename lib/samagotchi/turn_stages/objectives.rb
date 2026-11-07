# frozen_string_literal: true

require "securerandom"
require_relative "../log"
require_relative "../objectives"
require_relative "../objectives_audit"
require_relative "../owner_prompt"
require_relative "../system_one/client"

module Samagotchi
  module TurnStages
    # The session's objectives over a turn (Samagotchi::Objectives is the
    # list itself; inside this class the bare name is this stage): System 1's
    # audit of what comes in at a turn's start and what goes out at its end
    # (ObjectivesAudit), the view announced when it changed, and the model's
    # proposals kept as cards until the turn is over. Its state is those
    # proposals under their mutex, the last view announced and the audit.
    class Objectives
      # @param side_judgments [SideJudgments] the Engine's side asks (the audit's kinds)
      # @param host_registry [HostRegistry] System 1's client resolves its host here
      # @param state_dir [#call] the sessions dir
      # @param recording [#call] (client, judgment, session, mode:) → the client saving its runs
      # @param runs [#call] the Engine's SystemOne::Runs
      # @param synchronize [#call] (&block) runs the block under the event lock (Engine#synchronize_events)
      # @param announce [#call] (event) tells the observers (Engine#announce)
      # @param running [#call] the running turn's conversation, nil between turns (Engine#live_conversation)
      # @param show_card [#call] (**card) shows a card (Engine#show_card)
      def initialize(side_judgments:, host_registry:, state_dir:, recording:, runs:, synchronize:, announce:, running:, show_card:)
        @side_judgments = side_judgments
        @state_dir = state_dir
        @synchronize = synchronize
        @announce = announce
        @running = running
        @show_card = show_card
        # The last view announced (#announce), under the event lock.
        @announced = nil
        # The model's proposals until the turn is over (#finally).
        @proposals = []
        @proposals_mutex = Mutex.new
        # With saving off nothing would come of an ask, so none is made.
        @audit = ObjectivesAudit.new(
          side: side_judgments, state_dir: state_dir,
          client_for: lambda do |judgment, session|
            next nil unless runs.call.on?

            recording.call(SystemOne::Client.from_config(host_registry: host_registry, mode: ObjectivesAudit::MODE, tag: :system_one),
                           judgment, session, mode: nil)
          end
        )
      end

      # System 1 on the objectives, in audit (ObjectivesAudit), at a turn's
      # start: the owner's turns only, and for a message a person's: a
      # reminder's or a delegate's prompt isn't one.
      def incoming(turn)
        return unless turn.prompt.is_a?(String) && turn.origin.human? && OwnerPrompt.turn?(session: turn.session, author: turn.origin.author)

        @audit.incoming(turn.session, turn.prompt)
      end

      # The turn's answer, after the end event and before :after_turn (the
      # caller skips a canceled or exhausted turn): the owner's turns only.
      def outgoing(turn, result)
        return unless OwnerPrompt.turn?(session: turn.session, author: turn.origin.author)

        @audit.outgoing(turn.session, result.text)
      end

      # A note added between turns (Engine#add_context_note): incoming too.
      def note(session, note) = @audit.note(session, note)

      # The session's objectives as the page draws them (Objectives.view), when
      # that differs from the last announced: after an edit (its file written,
      # pending), once a list note is in, at a turn's end (its moves) and after
      # a rollback. A session with no list announces nothing. It only informs:
      # a failure is logged, never the turn's.
      def announce(session)
        return unless session

        @synchronize.call do
          view = Samagotchi::Objectives.view(session.id, session.messages, state_dir: @state_dir.call, running: @running.call&.dup)
          next if view.nil? || view == @announced

          @announced = view
          @announce.call({ type: :objectives_updated, session_id: session.id, **view })
        end
      rescue StandardError => e
        Log.warn(:turn, "objectives_announce_failed", error: e.class.name, msg: e.message)
      end

      # A change the model proposes (the objectives tool), kept until the turn
      # is over, as TurnStages::ContextJudge's cards are: a card shown then is a quiet one, between turns, with its Apply kept
      # over a restart (CardStore), not a running turn's that says it waits on the
      # user. The same change twice in a turn is one card.
      # @return [Boolean] false past Objectives::PROPOSALS_PER_TURN
      def propose(proposal)
        @proposals_mutex.synchronize do
          next true if @proposals.any? { |p| p.line == proposal.line }
          next false if @proposals.size >= Samagotchi::Objectives::PROPOSALS_PER_TURN

          @proposals << proposal
          true
        end
      end

      # However +turn+ ended (Engine#run_turn's ensure, after the turn flag is
      # released): only a completed turn shows its proposal cards. A canceled,
      # failed or rolled-back turn keeps none, and its proposals are dropped
      # here so the next turn does not show them either: their Apply card
      # would sit after a turn whose `objectives propose` call is not in the
      # history (a rollback after Ctrl-C drops it).
      def finally(turn)
        turn.completed? ? show_proposals : discard_proposals(turn)
      end

      # For specs: the audit's asks' thread for +kind+ (ObjectivesAudit's
      # SideJudgments kinds), nil before any.
      def audit_thread(kind) = @side_judgments.thread(kind)

      # For specs: the proposals kept for the running turn (a copy).
      def proposals = @proposals_mutex.synchronize { @proposals.dup }

      private

      def show_proposals
        drain_proposals.each do |proposal|
          id = "objectives-#{SecureRandom.hex(4)}"
          @show_card.call(source: Samagotchi::Objectives::SOURCE, id: id, title: proposal.title, body: proposal.body,
                          actions: [{ label: "Apply", command: proposal.action_line(id) },
                                    { label: "Dismiss", command: "/objectives --card #{id} dismiss" }])
        end
      rescue StandardError => e
        Log.warn(:turn, "objectives_proposal_failed", error: e.class.name, msg: e.message)
      end

      def discard_proposals(turn)
        dropped = drain_proposals
        Log.info(:turn, "objectives_proposals_dropped", count: dropped.size, outcome: turn.outcome.to_s) unless dropped.empty?
      end

      def drain_proposals
        @proposals_mutex.synchronize { @proposals.slice!(0..) }
      end
    end
  end
end
