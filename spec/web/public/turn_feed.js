// Feeds stream events into a turn_model turn the way turn_view.js does
// (its turnStarted/generationStarted/chunk/... call the same model
// functions); null for the types the turn view doesn't take.
import * as model from "../../../lib/samagotchi/web/public/turn_model.js";

export function applyEvent(turn, event) {
  switch (event?.type) {
    case "turn_started": return model.turnStarted(turn);
    case "generation_started": return model.generationStarted(turn, event.iteration ?? null);
    case "generation_chunk":
      if (!event.text && !event.thinking) return null;
      return model.chunk(turn, { text: event.text, thinking: event.thinking, iteration: event.iteration ?? null });
    case "generation_completed": return model.generationCompleted(turn);
    case "tool_call_started": return model.toolStarted(turn, event);
    case "tool_call_completed": return model.toolCompleted(turn, event);
    case "turn_completed": case "turn_canceled": case "turn_failed": return model.turnEnded(turn);
    default: return null;
  }
}
