import { GRIP_OPEN_PX } from "./composer_size.js";
import { waitingOn } from "./notify.js";

// How many session cards the top strip shows for its width in px: a card
// needs about 360 px plus a 12 px gap next to the 150 px "All sessions" tile;
// never fewer than 3 (narrow screens scroll them), never more than 6.
const STRIP_TILE_PX = 150;
const STRIP_GAP_PX = 12;
const STRIP_CARD_PX = 360;

export function stripColumns(width) {
  const fit = Math.floor(((width || 0) - STRIP_TILE_PX - STRIP_GAP_PX) / (STRIP_CARD_PX + STRIP_GAP_PX));
  return Math.min(6, Math.max(3, fit));
}

// The hidden strip's "▾ sessions" pill carries the list's count, and how
// many of those sessions a worker runs (the cards' green "live" badge), so a
// user who hid the strip still sees there is a live session to go back to.
// And how many wait on the user (notify.js waitingOn: a question, an
// approval, a card), so a hidden strip still says one needs an answer.
// Plain text parts; live and waiting are "" when none. Zero sessions keep
// the bare label. The count is sessions (a folded delegate counts), the
// number the "All sessions" tile shows.
export function stripShowParts(sessions) {
  const list = sessions || [];
  const n = list.length;
  const liveN = list.filter((s) => s && s.owner === "worker").length;
  const waitingN = list.filter((s) => waitingOn(s)).length;
  return {
    count: n ? `${n} ${n === 1 ? "session" : "sessions"}` : "sessions",
    live: liveN ? `${liveN} live` : "",
    waiting: waitingN ? `${waitingN} waiting` : "",
  };
}

// A window this short hides the strip by itself: at ~500-700 px the stage
// is capped low and a card that waits there (a question, an approval) is
// cut off below the strip.
export const SHORT_WINDOW_QUERY = "(max-height: 700px)";

// The strip's grip: the handle on the edge between the strip and the chat
// (the composer's grip's twin, mirrored: that one folds the box down, this
// one puts the strip away up). +dy+ is the release y minus the press y, so a
// drag up is negative. Decided on release only (the strip snaps, it does not
// follow the pointer): |dy| below GRIP_OPEN_PX is a tap, which toggles either
// way (a hidden strip's grip has no other way to come back, and a shown
// one's neither); a longer drag only fires the way it points: up (past
// STRIP_HIDE_PX) hides the shown strip, down (past GRIP_OPEN_PX) shows the
// hidden one. Anything else is null: a short drag the wrong way does nothing.
export const STRIP_HIDE_PX = 32; // a drag up this far hides the shown strip
export function stripGripAction({ hidden, dy }) {
  if (Math.abs(dy) < GRIP_OPEN_PX) return hidden ? "show" : "hide"; // a tap
  if (hidden) return dy >= GRIP_OPEN_PX ? "show" : null;
  return dy <= -STRIP_HIDE_PX ? "hide" : null;
}

// The grip's title (D7: the grip owns it; composer_grip.js's drawFoldControls
// writes the composer's the same way). willToggle: the drag in progress would
// act on release.
export function stripGripTitle({ hidden, willToggle }) {
  if (willToggle) return hidden ? "Release to show the latest sessions" : "Release to hide the latest sessions";
  return hidden ? "Drag down or click to show the latest sessions" : "Drag up or click to hide the latest sessions";
}

// Whether the strip is hidden: the user's own hide (saved), or a short
// window unless the user showed it (the pill) since it got short.
export function stripAutoHidden({ saved, short, shownWhileShort }) {
  return !!saved || (!!short && !shownWhileShort);
}
