// Where a snapshot's card or notice goes by its stamp: the id of the turn
// opening it comes after (+opening_id+, Bridge::CardPlaces#opening_of: a
// prompt's turn_id, a wake note's, /continue no's reason line's own id). The
// page finds that opening's bubble (data-turn-id on a prompt, data-opening-id
// on a wake note or a reason line, turn_html.js) and the entry goes before
// the next turn's opening, or at the end. No counting, so the page and the
// worker can't disagree on which bubbles open turns. An entry with no stamp
// (an older worker's, one before every opening), or whose opening the page
// doesn't draw, falls back to its count (card.js cardPlace, turns_since).
// A new module: the static JS is unversioned (docs/internals/web-frontend.md).
import { cardPlace } from "./card.js";

// The opening bubble +id+ names among the turns' openings (oldest first,
// bubbles.js turnPromptBubbles), or -1.
export function stampedOpening(userBubbles, id) {
  if (!id) return -1;
  const stamp = String(id);
  return userBubbles.findIndex((el) => el.dataset?.turnId === stamp || el.dataset?.openingId === stamp);
}

// The element +entry+ goes before: the opening after its stamped one (null:
// the end), else what its count says (null: the end too).
export function snapshotPlace(userBubbles, entry) {
  const at = stampedOpening(userBubbles, entry?.opening_id);
  if (at < 0) return cardPlace(userBubbles, entry);
  return userBubbles[at + 1] || null;
}
