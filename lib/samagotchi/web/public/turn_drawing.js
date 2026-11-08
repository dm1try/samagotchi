// A finished turn's drawing (chi web's turn_drawings: {events, end}, the
// Bridge's TurnDrawings unfolded once, in Ruby): what the live page drew for
// the turn, which a reload draws again (turn_block.js drawnTurnNodes feeds
// these events to a live turn block) instead of rebuilding the turn from its
// saved messages. Pure, no DOM: timing.js folds a drawing into its steps
// here (the working set's rows, the footprint), and a new module, so a
// cached older page never imports a name its modules lack.
import * as model from "./turn_model.js";

const END_KINDS = Object.freeze({ turn_completed: "completed", turn_canceled: "canceled", turn_failed: "failed" });

// How the drawn turn ended ("completed", "canceled", "failed"), from its end
// event's type.
export function drawnKind(end) {
  return END_KINDS[end?.type] || "completed";
}

// The drawing's events folded as turn_model.js folds a live turn (the same
// exports the turn block calls), ended: its gens, each with its tool rows.
export function drawingTurn(drawing) {
  const turn = model.newTurn();
  for (const event of drawing?.events || []) {
    switch (event?.type) {
      case "turn_started": model.turnStarted(turn); break;
      case "generation_started": model.generationStarted(turn, event.iteration ?? null); break;
      case "generation_chunk":
        if (event.text || event.thinking) model.chunk(turn, { text: event.text || "", thinking: event.thinking || "", iteration: event.iteration ?? null });
        break;
      case "tool_call_started": model.toolStarted(turn, event); break;
      case "tool_call_completed": model.toolCompleted(turn, event); break;
      default: break;
    }
  }
  model.turnEnded(turn);
  return turn;
}

// The ids of the drawn turns among +items+ (their `drawn` stamps, a
// drawing for each in +drawings+).
export function drawnIds(items, drawings) {
  if (!drawings) return new Set();
  return new Set((items || []).map((item) => item?.drawn).filter((id) => typeof id === "string" && drawings[id]));
}
