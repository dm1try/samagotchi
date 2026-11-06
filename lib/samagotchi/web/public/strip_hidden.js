import { readStored, writeStored } from "./storage.js";
import { SHORT_WINDOW_QUERY, stripAutoHidden } from "./strip.js";
import { createStripGrip } from "./strip_grip.js";

// The saved choice (storage.js): the strip hidden; chi_zen is zen mode's old
// name, read when the new key was never written.
export const STRIP_HIDDEN_KEY = "chi_strip_hidden";
const ZEN_KEY = "chi_zen";

// The latest-sessions strip hidden or shown (used by app.js): the body's
// strip-hidden class, the grip (strip_grip.js) that toggles it, and the short
// window's rule. The strip can be hidden for more chat room; the choice stays
// per browser (it replaced zen mode, so a zen user starts hidden). A short
// window hides the strip by itself, so the stage keeps room for a card that
// waits (its question and choices); the grip brings it back until the window
// is tall again. Not saved: the saved choice is the user's own hide or show.
//
// +gripEl+: #stripGrip. +body+: the page's body (the class). +onApply()+:
// after each change (the top bar's title follows: app.js updateSessionTitle).
// +closeFamilyPop()+: a hide takes the strip's family popover along. +win+:
// the window (matchMedia). +storage+: storage.js's guarded read and write.
// Applied once at creation.
export function createStripHidden({
  gripEl, body = globalThis.document.body, onApply, closeFamilyPop, win = globalThis,
  storage = { read: readStored, write: writeStored },
}) {
  const shortWindow = win.matchMedia(SHORT_WINDOW_QUERY);
  let shownWhileShort = false;

  function saved() {
    const value = storage.read(STRIP_HIDDEN_KEY);
    return value === null ? storage.read(ZEN_KEY) === "1" : value === "1";
  }

  // The grip is given the hidden state and the toggle; it speaks its own
  // title and aria-expanded, refreshed after every change.
  const gripRefresh = createStripGrip({
    gripEl,
    isHidden: () => body.classList.contains("strip-hidden"),
    setHidden: (hidden) => setHidden(hidden),
  });

  function apply() {
    body.classList.toggle("strip-hidden", stripAutoHidden({
      saved: saved(), short: shortWindow.matches, shownWhileShort,
    }));
    gripRefresh();
    onApply();
  }

  function setHidden(hidden) {
    if (hidden) closeFamilyPop();
    storage.write(STRIP_HIDDEN_KEY, hidden ? "1" : "0");
    shownWhileShort = !hidden && shortWindow.matches;
    apply();
  }

  apply();
  shortWindow.addEventListener("change", () => {
    if (!shortWindow.matches) shownWhileShort = false;
    apply();
  });

  return { setHidden };
}
