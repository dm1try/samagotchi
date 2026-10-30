import { easeScrollTo, FOLLOW_MS } from "./scroll.js";
import { FOLD_MS } from "./stage_view.js";
import { reducedMotion, STAGE_GAP } from "./stage_frame.js";
import { toastBottom } from "./toast_place.js";

// What floats over the history (used by app.js): the composer card, and in
// the stage view the stage above it. Two measures follow it.
//
// The reserve: the card floats over the history, so the history's bottom
// padding (--dock-h on #center, index.html) is kept at the card's height,
// and a reader at the end stays pinned there, since the card grows (text,
// chips, Cancel, a wrapping footer) under a reader at the end. In the stage
// view the stage floats above the card, out of the dock's flow
// (stage_view.js): the reserve counts it too, with its STAGE_GAP, while it
// shows. A leaving stage (the hand-off's slide) no longer counts: the
// reserve eases down over the slide (#center.reserve-easing).
//
// The toast: it sits above the session's composer card (measured: it grows
// with a wrapping footer or a taller box), so it never covers the card's
// controls, and above the stage while it shows and a fresh link's open
// model panel (toast_place.js); with no card in sight (the start page, all
// sessions) the CSS's 24 px from the bottom (--toast-bottom unset).
//
// +stageEl+: the stage (stage_view.js). +atHistoryEnd()+:
// the reader is at the history's end (app.js, scroll.js's threshold).
// +reduce()+ / +ease+: prefers-reduced-motion and the eased follow
// (scroll.js), defaults the page's.
// The observers that call these are installed here: the dock's and the
// stage's size, the stage showing, hiding or leaving, the window's size and
// the model panel's. app.js calls placeToast() when the page enters or
// leaves a session and when a toast shows or goes (toasts.js onChange).
export function createDockReserve({
  dockEl, centerEl, stageEl, historyEl, toastEl, modelPanelEl, atHistoryEnd,
  reduce = reducedMotion, ease = easeScrollTo,
}) {
  const doc = dockEl.ownerDocument;
  const win = doc.defaultView;

  function dockReserve() {
    const shown = !stageEl.hidden && !stageEl.classList.contains("leaving");
    return dockEl.offsetHeight + (shown ? stageEl.offsetHeight + STAGE_GAP : 0);
  }
  const historyEnd = () => historyEl.scrollHeight - historyEl.clientHeight;

  // A reader at the end stays there when the reserve changes: at once for the
  // composer card, eased for the stage (+fromStage+: it appeared, grew or
  // leaves), so the history glides rather than jumps. An eased follow running
  // counts as at the end.
  function updateReserve({ fromStage = false } = {}) {
    const follow = atHistoryEnd() || historyEl.dataset.following !== undefined;
    const leaving = stageEl.classList.contains("leaving");
    centerEl.classList.toggle("reserve-easing", leaving);
    const reserve = `${dockReserve()}px`;
    const changed = centerEl.style.getPropertyValue("--dock-h") !== reserve;
    if (changed) centerEl.style.setProperty("--dock-h", reserve);
    if (changed && follow) {
      if (fromStage) ease(historyEl, historyEnd, { ms: leaving ? FOLD_MS : FOLLOW_MS, reduce: reduce() });
      else if (historyEl.dataset.following === undefined) historyEl.scrollTop = historyEl.scrollHeight;
    }
    placeToast();
  }

  function placeToast() {
    const r = dockEl.getBoundingClientRect();
    const shownTop = (el) => {
      const box = el && !el.hidden ? el.getBoundingClientRect() : null;
      return box && box.height > 0 ? box.top : null;
    };
    const px = toastBottom({
      inSession: doc.body.classList.contains("has-session") && r.height > 0,
      viewportHeight: win.innerHeight,
      dockTop: r.top,
      tops: [shownTop(stageEl), shownTop(modelPanelEl)],
      toastHeight: toastEl.offsetHeight,
    });
    const bottom = px === null ? "" : `${px}px`;
    const root = doc.documentElement.style;
    if (root.getPropertyValue("--toast-bottom") !== bottom) {
      if (bottom) root.setProperty("--toast-bottom", bottom);
      else root.removeProperty("--toast-bottom");
    }
  }

  const dockObserver = new win.ResizeObserver((entries) => updateReserve({ fromStage: entries.some((e) => e.target === stageEl) }));
  dockObserver.observe(dockEl);
  dockObserver.observe(stageEl);
  // Only showing, hiding and leaving change the reserve (not the stage's
  // other classes: waiting, in-use…).
  let stageShown = "";
  new win.MutationObserver(() => {
    const shown = `${stageEl.hidden}|${stageEl.classList.contains("leaving")}`;
    if (shown === stageShown) return;
    stageShown = shown;
    updateReserve({ fromStage: true });
  }).observe(stageEl, { attributes: true, attributeFilter: ["class", "hidden"] });
  win.addEventListener("resize", () => placeToast());
  // The model panel opening, closing or changing height (its list filters).
  new win.ResizeObserver(() => placeToast()).observe(modelPanelEl);

  return { updateReserve, placeToast };
}
