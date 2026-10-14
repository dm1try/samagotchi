// The stage view's in-use watch (stage_view.js): the stage is in use while
// the pointer is over it (tracked on the stage itself: :hover goes stale
// when children change), after a touch or wheel in the last 4 s (phones
// have no hover), with keyboard focus or a selection in it. While an ended
// turn waits for its hand-off it ticks every WATCH_MS: the stage wears
// `in-use`, and the stage's +onTick+ (stage_model.js handOffDue) says when
// the hand-off is due, with the quiet clock this watch keeps.
import { inUseFrom } from "./stage_model.js";

const WATCH_MS = 200;

// +watching()+: the stage still holds an ended turn (else a tick stops the
// watch). +onTick({ inUse, quietSinceMs, nowMs })+ returns { due,
// quietSinceMs }; +onDue()+ hands off.
export function createInUseWatch({ stage, watching, onTick, onDue }) {
  let watchTimer = null;
  let quietSince = null;
  let pointerIn = false;
  let lastTouch = 0;

  stage.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") pointerIn = true; });
  stage.addEventListener("pointermove", (e) => { if (e.pointerType === "mouse") pointerIn = true; });
  stage.addEventListener("pointerleave", () => { pointerIn = false; });
  // Scrolling needs the pointer over it, a touch or keyboard focus; the
  // stage's own scrolls (follow, the answer's top) are no use.
  for (const type of ["touchstart", "touchmove", "wheel"]) {
    stage.addEventListener(type, () => { lastTouch = Date.now(); }, { passive: true, capture: true });
  }

  function inUse(nowMs) {
    const active = document.activeElement;
    const sel = window.getSelection();
    return inUseFrom({
      pointerIn,
      lastTouchMs: lastTouch,
      // A clicked button keeps the focus in Chrome: only keyboard focus and
      // a field being typed in count.
      focusInside: !!active && stage.contains(active) && active.matches(":focus-visible"),
      selectionInside: !!sel && !sel.isCollapsed && stage.contains(sel.anchorNode),
      nowMs,
    });
  }

  function stopWatch() {
    clearInterval(watchTimer);
    watchTimer = null;
    quietSince = null;
    stage.classList.remove("in-use");
  }

  function startWatch() {
    stopWatch();
    watchTimer = setInterval(() => {
      if (!watching()) return stopWatch();
      const nowMs = Date.now();
      const busy = inUse(nowMs);
      stage.classList.toggle("in-use", busy);
      const r = onTick({ inUse: busy, quietSinceMs: quietSince, nowMs });
      quietSince = r.quietSinceMs;
      if (r.due) onDue();
    }, WATCH_MS);
  }

  return { start: startWatch, stop: stopWatch };
}
