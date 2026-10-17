// The composer's height. It grows with its text up to a cap; the grip on
// its top edge sets a taller floor (the cap then is at least that floor).
export const PROMPT_MIN_PX = 72; // about three lines of the 15 px field: the start page
export const PROMPT_LINE_PX = 26; // one line (15 px × 1.45 + 4 padding): in a session
const PROMPT_CAP_SHARE = 0.35; // of the window's height, for growing with text
const PROMPT_GRIP_SHARE = 0.5; // of the window's height, for the grip
export const GRIP_FOLD_PX = 32; // a drag down this far past what the box shows folds the composer (on release)
export const GRIP_OPEN_PX = 8; // a drag up this far from the folded handle opens it; less is a tap

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

// Whether a grip drag asks to fold the composer: it wants the box at least
// GRIP_FOLD_PX less than the box actually shows (+shownPx+, after the box
// fitted itself: with text in it the content sets the height, so measuring
// against the floor would fold a tall box on a short pull).
export function gripFolds({ requestedPx, shownPx }) {
  return shownPx - requestedPx >= GRIP_FOLD_PX;
}
