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
// Plain text parts; live is "" when none. Zero sessions keep the bare label.
export function stripShowParts(sessions) {
  const list = sessions || [];
  const n = list.length;
  const liveN = list.filter((s) => s && s.owner === "worker").length;
  return {
    count: n ? `${n} ${n === 1 ? "session" : "sessions"}` : "sessions",
    live: liveN ? `${liveN} live` : "",
  };
}
