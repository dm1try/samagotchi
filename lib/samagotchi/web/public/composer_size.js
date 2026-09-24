// The composer's height. It grows with its text up to a cap; the grip on
// its top edge sets a taller floor (the cap then is at least that floor).
export const PROMPT_MIN_PX = 72; // about three lines of the 15 px field
export const PROMPT_CAP_SHARE = 0.35; // of the window's height, for growing with text
export const PROMPT_GRIP_SHARE = 0.5; // of the window's height, for the grip

// contentPx: the text's height (scrollHeight plus borders); floorPx: the
// grip's height, or null.
export function promptHeight({ contentPx, floorPx = null, viewportPx }) {
  const floor = Math.max(PROMPT_MIN_PX, floorPx || 0);
  const cap = Math.max(floor, Math.round(viewportPx * PROMPT_CAP_SHARE));
  return { height: Math.min(Math.max(contentPx, floor), cap), scrolls: contentPx > cap };
}

// A grip drag: the floor it asks for, kept between the minimum and the
// grip's share of the window.
export function gripFloor(px, viewportPx) {
  return Math.round(Math.min(Math.max(px, PROMPT_MIN_PX), viewportPx * PROMPT_GRIP_SHARE));
}
