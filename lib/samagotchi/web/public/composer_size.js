// The composer's height. It grows with its text up to a cap; the grip on
// its top edge sets a taller floor (the cap then is at least that floor).
export const PROMPT_MIN_PX = 72; // about three lines of the 15 px field: the start page
export const PROMPT_LINE_PX = 26; // one line (15 px × 1.45 + 4 padding): in a session
export const PROMPT_CAP_SHARE = 0.35; // of the window's height, for growing with text
export const PROMPT_GRIP_SHARE = 0.5; // of the window's height, for the grip

// contentPx: the text's height (scrollHeight plus borders); floorPx: the
// grip's height, or null; minPx: the empty box's height.
export function promptHeight({ contentPx, floorPx = null, viewportPx, minPx = PROMPT_MIN_PX }) {
  const floor = Math.max(minPx, floorPx || 0);
  const cap = Math.max(floor, Math.round(viewportPx * PROMPT_CAP_SHARE));
  return { height: Math.min(Math.max(contentPx, floor), cap), scrolls: contentPx > cap };
}

// A grip drag: the floor it asks for, kept between the minimum and the
// grip's share of the window.
export function gripFloor(px, viewportPx, minPx = PROMPT_MIN_PX) {
  return Math.round(Math.min(Math.max(px, minPx), viewportPx * PROMPT_GRIP_SHARE));
}
