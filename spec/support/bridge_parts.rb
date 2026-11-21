# frozen_string_literal: true

require "samagotchi/session_observer"
require "samagotchi/turn_state"
require "samagotchi/question_desk"
require "samagotchi/steer_cut"

# The parts of an Engine that a Bridge (and the Worker's collaborators) take
# instead of its forwards: the event log, the turn state, the question desk
# and the steer cut. Include it in the example group.
module BridgeParts
  # For a spec that builds a Bridge on a real Engine:
  # +Samagotchi::Bridge.new(engine: engine, **bridge_parts(engine), …)+.
  # @param engine [Samagotchi::Engine]
  # @return [Hash{Symbol => Object}] the Engine's own event_log:, turn_state:,
  #   question_desk:, steer_cut:
  def bridge_parts(engine)
    { event_log: engine.event_log, turn_state: engine.turn_state, question_desk: engine.question_desk,
      steer_cut: engine.steer_cut }
  end

  # For the Worker specs that double the Engine
  # (+instance_double(Samagotchi::Engine, **idle_engine_parts, …)+) only:
  # real, idle objects, so a worker built on the double runs a real Bridge.
  # The desk's lambdas are inert: no session, no interface, no controller.
  # @param clock [#call] the turn state's and the steer cut's clock
  # @return [Hash{Symbol => Object}] event_log:, turn_state:, question_desk:,
  #   steer_cut:
  def idle_engine_parts(clock: -> { 0.0 })
    desk = Samagotchi::QuestionDesk.new(session: -> {}, state_dir: -> {}, emit: ->(_) {},
                                        cancel_controller: -> {}, interface: -> {}, user_input: ->(_) {})
    { event_log: Samagotchi::SessionObserver.new, turn_state: Samagotchi::TurnState.new(clock: clock),
      question_desk: desk, steer_cut: Samagotchi::SteerCut.new(clock: clock, controller: -> {}, cut_after: -> { 0.0 }) }
  end
end
