# frozen_string_literal: true

module Samagotchi
  # A session worker's continue offer: what it announces when a turn runs out
  # of iterations, when a prompt or a reminder drops the offer, when a
  # /continue answers it, and the continue turn a yes runs. TurnFlow keeps
  # the offer itself (its checkpoint and context); this is the worker's side
  # of it, which every UI hears about.
  class ContinueOffer
    # @param engine [Engine] announces, records activity
    # @param turn_flow [TurnFlow] owns the offer
    # @param run_turn [#call] (prompt, **turn_args, &block) the worker's
    #   run_engine_turn
    # @param max_iterations [#call] (no_interrupt) → Integer
    def initialize(engine:, turn_flow:, run_turn:, max_iterations:)
      @engine = engine
      @turn_flow = turn_flow
      @run_turn = run_turn
      @max_iterations = max_iterations
    end

    def awaiting? = @turn_flow.awaiting_continue?

    # TurnFlow keeps the checkpoint (a cancelled turn's, for !rollback) and
    # the continue offer of a turn that ran out of iterations; an offer made
    # (or kept, after a cancelled continue turn) is announced.
    def after_turn(result, continue: false, no_interrupt: false)
      outcome = @turn_flow.after_turn(result, continue: continue, no_interrupt: no_interrupt)
      return unless outcome == :continue_offered || outcome == :continue_cancelled

      announce_offer
    end

    # A prompt (or a reminder turn) taken while a continue is offered
    # replaces the answer (D2): the offer goes, the partial turn stays.
    def drop(origin)
      return unless awaiting?

      @engine.synchronize_events do
        @turn_flow.drop_offer!
        @engine.announce(type: :continue_resolved, decision: "dropped", client_id: origin&.dig(:client_id))
      end
      @engine.record_activity
    end

    # Whether a command's +result+ answered the offer that was pending
    # (+awaiting+) as it started.
    def resolved?(awaiting, result)
      awaiting && result.decision && result.decision != :invalid ? true : false
    end

    # Called with the event log held, before the command's command_ran.
    def announce_resolved(result, command)
      @engine.announce(type: :continue_resolved, decision: result.decision.to_s, client_id: command[:client_id])
    end

    # After a resolving command's command_ran and save.
    def resolved(result)
      # An offer answered without a turn ("no") is activity: the recap
      # written at the offer (it says the turn stopped) gets rewritten.
      @engine.record_activity unless result.resume
    end

    # The continue offer was answered yes: resume the conversation without a
    # user message, with the iteration limit the offer's turn had. A failure
    # keeps the offer, as the REPL does ("continue prompt preserved").
    def run_continue_turn(command)
      offer = @turn_flow.offer
      @turn_flow.before_continue_turn
      @run_turn.call(nil, continue: true, origin: { client_id: command[:client_id] }.compact,
                          max_iterations: @max_iterations.call(offer[:no_interrupt])) do |result, error|
        if error
          announce_offer(offer)
        else
          after_turn(result, continue: true, no_interrupt: offer[:no_interrupt])
        end
      end
    end

    private

    def announce_offer(offer = @turn_flow.offer)
      @engine.announce(type: :continue_offered, context: offer[:context], no_interrupt: offer[:no_interrupt])
    end
  end
end
