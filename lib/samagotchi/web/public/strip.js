import { waitingOn } from "./notify.js";

// How many session cards the top strip shows for its width in px: a card
// needs about 360 px plus a 12 px gap next to the 150 px "All sessions" tile;
// never fewer than 3 (narrow screens scroll them), never more than 6.
export const STRIP_TILE_PX = 150;
export const STRIP_GAP_PX = 12;
export const STRIP_CARD_PX = 360;

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
// the bare label.
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

// Whether the strip is hidden: the user's own hide (saved), or a short
// window unless the user showed it (the pill) since it got short.
export function stripAutoHidden({ saved, short, shownWhileShort }) {
  return !!saved || (!!short && !shownWhileShort);
}
