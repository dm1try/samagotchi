// Where a saved recap goes by its stamp: the id of the last turn opening it
// covers (+openingId+, RecapPlace.opening_id: a prompt's turn_id, a wake
// note's, /continue no's reason line's own id), as a snapshot's card goes
// (card_stamps.js). It sits before the opening after that one's bubble, or
// at the end. No counting, so a rollback or a check-in can't put it a turn
// off. Without a stamp (an older worker's recap) or when the page doesn't
// draw that opening, it falls back to its count (format.js recapPlace).
// A new module: the static JS is unversioned (docs/internals/web-frontend.md).
import { stampedOpening } from "./card_stamps.js";
import { recapPlace } from "./format.js";

// The bubble the recap goes before (null: the end).
export function recapStampPlace(userBubbles, openingId, turnsSince) {
  const at = stampedOpening(userBubbles, openingId);
  if (at < 0) return recapPlace(userBubbles, turnsSince);
  return userBubbles[at + 1] || null;
}
