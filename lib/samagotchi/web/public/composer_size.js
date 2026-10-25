// The composer's height and the gestures of the grip on its top edge. The
// height grows with the text up to a cap; the grip sets a taller floor (the
// cap then is at least that floor), and no floor — saved in another window or
// dragged here — takes more than half of the window the box is shown in. A
// release of the grip is one gesture: a drag that resizes, a drag far enough
// down that folds the box away, or a click (which, expanded, folds too — after
// a delay, so a double-click can still reset the height).
export const PROMPT_MIN_PX = 72; // about three lines of the 15 px field: the start page
export const PROMPT_LINE_PX = 26; // one line (15 px × 1.45 + 4 padding): in a session
const PROMPT_CAP_SHARE = 0.35; // of the window's height, for growing with text
const PROMPT_GRIP_SHARE = 0.5; // of the window's height, for the grip
export const GRIP_FOLD_PX = 32; // a drag down this far past what the box shows folds the composer (on release)
export const GRIP_OPEN_PX = 8; // a drag up this far from the folded handle opens it; less is a tap
export const GRIP_CLICK_FOLD_MS = 250; // how long a click on the expanded grip waits before folding, so a second click in that window can still mean a reset

// contentPx: the text's height (scrollHeight plus borders); floorPx: the
// grip's height, or null; minPx: the empty box's height.
export function promptHeight({ contentPx, floorPx = null, viewportPx, minPx = PROMPT_MIN_PX }) {
  // The floor, as THIS window can hold it: a floor saved in a bigger window
  // (a rotated phone, a resized window, another device on the same origin) is
  // held down to the share a drag may set here, and comes back whole when the
  // window is big again — only the height shown shrinks, never the saved floor.
  const floor = gripFloor(floorPx, viewportPx, minPx);
  const cap = Math.max(floor, Math.round(viewportPx * PROMPT_CAP_SHARE));
  return { height: Math.min(Math.max(contentPx, floor), cap), scrolls: contentPx > cap };
}

// A grip drag: the floor it asks for, kept between the minimum and the
// grip's share of the window. The same rule fits a floor saved earlier (see
// promptHeight), so the box never takes more of a window than a drag in it
// could have given it.
export function gripFloor(px, viewportPx, minPx = PROMPT_MIN_PX) {
  return Math.max(minPx, Math.min(px || 0, Math.round(viewportPx * PROMPT_GRIP_SHARE)));
}

// Whether a grip drag asks to fold the composer: it wants the box at least
// GRIP_FOLD_PX less than the box actually shows (+shownPx+, after the box
// fitted itself: with text in it the content sets the height, so measuring
// against the floor would fold a tall box on a short pull).
export function gripFolds({ requestedPx, shownPx }) {
  return shownPx - requestedPx >= GRIP_FOLD_PX;
}

// What a grip release asks for, decided from the press alone (the strip's
// grip's twin, strip.js's stripGripAction). +session+: is there a session (the
// start page's grip only resizes). +folded+: the composer is folded now.
// +dy+: the release y minus the press y, down positive. +willFold+: the drag is
// past GRIP_FOLD_PX below what the box shows. +pending+: an earlier click's fold
// is still waiting its GRIP_CLICK_FOLD_MS, so this release is the second click.
//   fold   – hide the box now
//   open   – a tap on the folded handle
//   hide   – the first click on the expanded grip: fold it after the delay
//   reset  – the second click in that delay: a double-click, so the height is reset
//   resize – a drag that stops short: keep the box and save the floor it asks for
//   none   – a drag down on the folded handle (pulling up opens it while dragging)
export function gripGesture({ session, folded, dy, willFold, pending }) {
  if (willFold) return "fold";
  const tap = Math.abs(dy) < GRIP_OPEN_PX;
  if (tap) {
    if (folded) return "open";
    if (!session) return "resize";
    return pending ? "reset" : "hide";
  }
  return folded ? "none" : "resize";
}
