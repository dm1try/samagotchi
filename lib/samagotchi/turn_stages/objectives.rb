# frozen_string_literal: true

require "securerandom"
require_relative "../cancellation_controller"
require_relative "../log"
require_relative "../objectives"
require_relative "../objectives_audit"
require_relative "../objectives_track"
require_relative "../owner_prompt"
require_relative "../system_one/client"

module Samagotchi
  module TurnStages
    # The session's objectives over a turn (Samagotchi::Objectives is the
    # list itself; inside this class the bare name is this stage): System 1's
    # audit of what comes in at a turn's start and what goes out at its end
    # (ObjectivesAudit), the view announced when it changed, and the model's
    # proposals kept as cards until the turn is over, and the tracker's
    # automatic read after a turn (ObjectivesTrack). Its state is those
    # proposals under their mutex, the automatic read's cancel under its own,
    # and the last view announced (under the event lock); the audit is built
    # per call.
    class Objectives
      # @param side_judgments [SideJudgments] the Engine's side asks (the audit's kinds)
      # @param host_registry [HostRegistry] System 1's client resolves its host here
      def initialize(side_judgments:, host_registry:)
        @side_judgments = side_judgments
        @host_registry = host_registry
        # The last view announced (#announce), under the event lock.
        @announced = nil
        # The model's proposals until the turn is over (#finally).
        @proposals = []
        @proposals_mutex = Mutex.new
        # The automatic read's cancel (#track), until the next turn's start.
        @track_cancel = nil
        @track_mutex = Mutex.new
      end

      # System 1 on the objectives, in audit (ObjectivesAudit), at a turn's
      # start: the owner's turns only, and for a message a person's: a
      # reminder's or a delegate's prompt isn't one.
      # @param recorder [SystemOne::Recorder] the audit's runs (built for this call)
      def incoming(turn, recorder:)
        return unless turn.prompt.is_a?(String) && turn.origin.human? && OwnerPrompt.turn?(session: turn.session, author: turn.origin.author)

        audit(turn.context.state_dir, recorder).incoming(turn.session, turn.prompt)
      end

      # The turn's answer, after the end event and before :after_turn (the
      # caller skips a canceled or exhausted turn): the owner's turns only.
      # @param recorder [SystemOne::Recorder] the audit's runs (built for this
      #   call: after a before_turn hook's model switch, the new model)
      def outgoing(turn, result, recorder:)
        return unless OwnerPrompt.turn?(session: turn.session, author: turn.origin.author)

        audit(turn.context.state_dir, recorder).outgoing(turn.session, result.text)
      end

      # After a completed turn (Engine#track_objectives_after), on the turn's
      # thread: the tracker by itself when ObjectivesTrack.after_turn? says so,
      # on a thread of its own kind (SideJudgments#start), so the turn's end
      # never waits. The stored conversation is read here, on this thread. The
      # next turn's start cancels it (#cancel_track); a typed track isn't.
      # @param engine [Engine] what ObjectivesTrack reads and shows through
      # @return [Thread, nil] the read's thread, nil when none started
      def track(turn, engine:)
        return nil unless ObjectivesTrack.after_turn?(engine, turn)

        # Its last read still runs (a turn as short as a request): that one
        # stays the one to cancel.
        if @side_judgments.in_flight?(ObjectivesTrack::SOURCE)
          Log.debug(:turn, "objectives_track_skipped", reason: "previous_read_running")
          return nil
        end

        session = turn.session
        conversation = session.messages.dup
        cancel = CancellationController.new
        thread = @side_judgments.start(ObjectivesTrack::SOURCE, warn: lambda { |e|
          Log.warn(:turn, "objectives_track_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        }) { ObjectivesTrack.run_after_turn(engine, session, conversation, cancel) }
        @track_mutex.synchronize { @track_cancel = cancel } if thread
        thread
      end

      # The automatic read's request cancelled (CancellationController#cancel!
      # :new_turn); nothing when none runs. At the very start of every turn
      # (Engine#begin_turn, before its own probes and waits), a wake's too, so
      # a one-slot server is free for it.
      def cancel_track
        cancel = @track_mutex.synchronize { @track_cancel.tap { @track_cancel = nil } }
        cancel&.cancel!(:new_turn)
      end

      # A note added between turns (Engine#add_context_note): incoming too.
      # @param recorder [SystemOne::Recorder] the audit's runs (built for this call)
      # @param state_dir [String] the sessions dir
      def note(session, note, recorder:, state_dir:) = audit(state_dir, recorder).note(session, note)

      # The session's objectives as the page draws them (Objectives.view), when
      # that differs from the last announced: after an edit (its file written,
      # pending), once a list note is in, at a turn's end (its moves) and after
      # a rollback. A session with no list announces nothing. The caller
      # (Engine#announce_objectives) holds the event lock, the one guard of
      # the last view, announces the event and logs a failure: it only
      # informs, never fails a turn.
      # @param state_dir [String] the sessions dir
      # @param running [Array<Hash>, nil] the running turn's conversation (Engine#live_conversation), nil between turns
      # @return [Hash, nil] the :objectives_updated event to announce, nil when the view is the same
      def announce(session, state_dir:, running:)
        view = Samagotchi::Objectives.view(session.id, session.messages, state_dir: state_dir, running: running&.dup)
        return if view.nil? || view == @announced

        @announced = view
        { type: :objectives_updated, session_id: session.id, **view }
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
      # history (a rollback after Ctrl-C drops it). The caller
      # (Engine#show_objective_proposals) shows the cards.
      # @return [Array<Hash>] the completed turn's cards (Engine#show_card's
      #   arguments); none for any other ending
      def finally(turn)
        return proposal_cards if turn.completed?

        discard_proposals(turn)
        []
      end

      # For specs: the audit's asks' thread for +kind+ (ObjectivesAudit's
      # SideJudgments kinds), nil before any.
      def audit_thread(kind) = @side_judgments.thread(kind)

      # For specs: the proposals kept for the running turn (a copy).
      def proposals = @proposals_mutex.synchronize { @proposals.dup }

      private

      def proposal_cards
        drain_proposals.map do |proposal|
          id = "objectives-#{SecureRandom.hex(4)}"
          { source: Samagotchi::Objectives::SOURCE, id: id, title: proposal.title, body: proposal.body,
            actions: [{ label: "Apply", command: proposal.action_line(id) },
                      { label: "Dismiss", command: "/objectives --card #{id} dismiss" }] }
        end
      end

      def discard_proposals(turn)
        dropped = drain_proposals
        Log.info(:turn, "objectives_proposals_dropped", count: dropped.size, outcome: turn.outcome.to_s) unless dropped.empty?
      end

      def drain_proposals
        @proposals_mutex.synchronize { @proposals.slice!(0..) }
      end

      # The audit for one call, over the values it is given: nothing of it
      # is kept. Its client is asked for only once an active objective is
      # there (ObjectivesAudit#ask), and with saving off nothing would come
      # of an ask, so none is made.
      def audit(state_dir, recorder)
        ObjectivesAudit.new(
          side: @side_judgments, state_dir: state_dir,
          client_for: lambda do |judgment, session|
            next nil unless recorder.saving?

            recorder.wrap(SystemOne::Client.from_config(host_registry: @host_registry, mode: ObjectivesAudit::MODE, tag: :system_one),
                          judgment, session, mode: nil)
          end
        )
      end
    end
  end
end
