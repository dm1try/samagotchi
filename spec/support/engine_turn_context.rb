# frozen_string_literal: true

require "samagotchi/turn_context"
require "samagotchi/tools/tool_surface"

# The TurnContext an Engine's gate (or its kernel's dispatch) is given for a
# call of an owner's turn on the Engine's current model, as Engine#generate
# freezes it: its session, model key, the bare model name the rules
# match and its tools' surface (the Engine's Registry now, no layers).
# +fields+ override any (author:, participant_mode:, origin:…).
#
#   gate.evaluate(call, context: engine_turn_context(engine), iteration: 1, params: "")
#
# #wiring_turn_context: the TurnContext a turn of +origin+ gets from a bare
# GuardrailWiring (its #begin_turn's git, participant and mode), as
# Engine#begin_turn builds it.
#
#   turn = wiring_turn_context(wiring, { client_id: "review:p_1", author: "p:p_1" }, session: session)
#   wiring.request_approval(verdict, turn)
module EngineTurnContext
  def engine_turn_context(engine, **fields)
    Samagotchi::TurnContext.none(session: engine.session, model_key: engine.model_key,
                                 fallback_model_key: engine.instance_variable_get(:@model_binding).fallback_model_key,
                                 model_name: engine.guardrail_model_name,
                                 surface: Samagotchi::Tools::ToolSurface.for(engine.tools), **fields)
  end

  def wiring_turn_context(wiring, origin, session: nil, **fields)
    origin = Samagotchi::TurnOrigin.of(origin)
    start = wiring.begin_turn(origin, session: session)
    Samagotchi::TurnContext.none(session: session, origin: origin, author: origin.participant_author,
                                 participant_mode: start.mode, participant: start.participant, git: start.git, **fields)
  end
end

RSpec.configure { |config| config.include EngineTurnContext }
