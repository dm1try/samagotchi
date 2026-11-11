// The cards that wait in the stage (stage_view.js, stage_model.js
// placeKind): what blocks the turn or asks the user stays in the stage
// whatever the turn's form, also when the turn is opened in the history
// (stage_opened.js).

// A card that waits for the user: a question or approval not answered, a
// continue offer not resolved.
export const PENDING = ".bubble.question:not(.answered):not(.cancelled), .bubble.continue:not(.resolved)";
// A running turn's card with actions (check-in's Nudge / Keep going / Stop)
// asks the user too, but the turn goes on: it waits only while the turn runs
// and never holds the hand-off (a turn cut short can leave it open).
export const ASKS = ".plugin-card[data-in-turn] .card-action";
// A plugin's warning stays in sight in the stage until the turn's end.
export const WARN_CARD = ".plugin-card.warn";

// +el+ waits in the stage: a pending card, an asking card's actions, a
// plugin's warning.
export function waitsInStage(el) {
  return !!(el?.matches?.(PENDING) || el?.querySelector?.(ASKS) || el?.matches?.(WARN_CARD));
}
