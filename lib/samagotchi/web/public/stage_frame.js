// The stage view's cap and frame (stage_view.js): the one place that
// writes the stage's height, and the stage's own scrolls. The cap: at most
// ~60% of the page (~80% with the cloud open), and never above the session
// panel. The frame: held and grow-only while the stage holds a turn
// (stage_model.js frameTarget), its growth eased. The stage's state comes
// in as getters (+isHolding+, +isCollapsed+, +isCloudOpen+); what the stage
// changes of the frame's goes through resetHeld and forgetContent.
import { frameTarget } from "./stage_model.js";
import { easeScrollTo } from "./scroll.js";

// The stage grows (a card, the long answer, the cloud opening) with a short
// ease: deliberate, never a snap.
const GROW_MS = 180;
const GROW_EASE = "cubic-bezier(.2,.7,.3,1)";
// The room between the stage and the composer card (index.html's margin-bottom).
const STAGE_GAP = 10;

export function reducedMotion() {
  return matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// +observed+: the elements whose size changes refit the frame (the stage's
// slots, in the order they are observed).
export function createStageFrame({ stage, scroller, status, cloud, queuedSlot, holdEl, asking, extras, dockEl, centerEl, composerEl, observed, isHolding, isCollapsed, isCloudOpen }) {
  // The frame (fitFrame): the height held while the turn runs and the
  // tallest content seen.
  let held = null;
  let maxContent = 0;
  let growth = null; // the running ease of the frame's growth (an Animation)
  let growthTo = 0; // its end height

  // The stage's own scrolls, eased (instant with reduced motion).
  function easeStage(top) {
    if (Math.abs(top - scroller.scrollTop) < 1) return;
    easeScrollTo(scroller, top, { reduce: reducedMotion() });
  }

  // +fn+ once the frame has grown for a change made now: two frames on (the
  // ResizeObserver starts the ease in the frame after the change), then at
  // the ease's end.
  function afterGrowth(fn) {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (growth?.playState === "running") growth.finished.then(fn, fn);
      else fn();
    }));
  }

  // ── the cap: at most ~60% of the page (~80% with the cloud open), and
  // never above the session panel (the dock is absolute: a tall composer or
  // a phone's keyboard would push the stage's top out) ────────────────────

  // Where the stage's scroll goes so +slot+ (the scroller's child) shows:
  // its end in sight, and the asking text's top too when it and the slot
  // (a waiting card) fit together (the reply reads from its start, the card
  // still in sight). null: nothing to show.
  function revealTop(slot) {
    if (stage.hidden || slot.hidden) return null;
    let top = Math.max(scroller.scrollTop, slot.offsetTop + slot.offsetHeight - scroller.clientHeight);
    if (!asking.hidden && asking.offsetTop < top && slot.offsetTop + slot.offsetHeight - asking.offsetTop <= scroller.clientHeight) top = asking.offsetTop;
    return top;
  }

  // Scrolls the stage to show +slot+: eased, or at once (+now+: the cap
  // dropped under it).
  function reveal(slot, { now = false } = {}) {
    const top = revealTop(slot);
    if (top === null) return;
    if (now) scroller.scrollTop = top;
    else easeStage(top);
  }

  function fitCap() {
    if (stage.hidden) return;
    // The composer card and the gap above it (the stage floats over them,
    // out of the dock's flow).
    const rest = dockEl.offsetHeight + STAGE_GAP;
    const room = centerEl.clientHeight - rest - 32;
    const share = window.innerHeight * (isCloudOpen() ? 0.8 : 0.6);
    const cap = Math.max(96, Math.round(Math.min(share, room)));
    const was = capPx();
    if (cap === was) return;
    stage.style.setProperty("--stage-max", `${cap}px`);
    fitFrame();
    // A smaller cap (a phone's keyboard came up) keeps a waiting card in
    // sight: the asking text above it would push it out. A larger one
    // leaves the reader's scroll alone.
    if (cap < was && stage.classList.contains("waiting")) {
      requestAnimationFrame(() => reveal(extras, { now: true }));
    }
  }
  new ResizeObserver(() => fitCap()).observe(centerEl);
  new ResizeObserver(() => fitCap()).observe(composerEl);
  window.addEventListener("resize", fitCap);

  // ── the frame: the one place that writes the stage's height ────────────
  // Nothing in the stage view jumps. The rules: the stage is out of the
  // dock's flow (index.html), so its height never moves the composer; while
  // it holds a turn its height is held and grow-only (frameTarget), so a
  // content change happens inside it; growth eases (frameTo); the chip is a
  // footer no content can push; the hand-off releases the turn at once
  // (releaseTurn) and empties the stage only after it slid away under the
  // composer (a transform, then finishFold/clearStage).

  // The stage's height, +px+. +animate+: a growth eases (GROW_MS, Web
  // Animations: the running ease is +growth+), unless motion is reduced or
  // the stage is hidden or collapsed; a shrink (the cap dropped) is at once.
  function frameTo(px, { animate = false } = {}) {
    const from = stage.offsetHeight;
    stage.style.height = `${px}px`;
    if (px === from) return;
    const ease = animate && px > from && !isCollapsed() && !stage.hidden && !document.hidden && !reducedMotion();
    if (growth && (!ease || growth.playState !== "running" || growthTo !== px)) {
      growth.cancel();
      growth = null;
    }
    if (!ease || growth) return;
    growth = stage.animate([{ height: `${from}px` }, { height: `${px}px` }], { duration: GROW_MS, easing: GROW_EASE });
    growthTo = px;
    const run = growth;
    run.finished.then(() => { if (growth === run) growth = null; }, () => {});
  }

  // Back to the content's own height (under the cap).
  function frameFree() {
    growth?.cancel();
    growth = null;
    stage.style.height = "";
  }

  function capPx() {
    return parseFloat(stage.style.getPropertyValue("--stage-max")) || Infinity;
  }

  // The scroller's content height: its last shown slot's end (offsetTop is
  // the scroller's own, whatever its scroll) and its bottom padding.
  function contentHeight() {
    const css = getComputedStyle(scroller);
    let end = parseFloat(css.paddingTop) || 0;
    for (const el of scroller.children) {
      if (el === holdEl || el.hidden || !el.getClientRects().length) continue;
      end = el.offsetTop + el.offsetHeight;
    }
    return end + (parseFloat(css.paddingBottom) || 0);
  }

  // Holds the frame while the stage holds a turn (stage_model.js
  // frameTarget: grow-only, clamped by the cap; free when collapsed or
  // released). Run from a ResizeObserver on the slots (after layout, before
  // paint: no frame shows the content's own height) and when the cap moves.
  function fitFrame() {
    if (stage.hidden || stage.classList.contains("leaving")) return;
    const content = scroller.hidden ? 0 : contentHeight();
    const holding = isHolding();
    const collapsed = isCollapsed();
    const holds = holding && !collapsed;
    maxContent = holds ? Math.max(maxContent, content) : 0;
    const mark = `${Math.max(0, Math.round(maxContent) - 1)}px`;
    if (holdEl.style.top !== mark) holdEl.style.top = mark;
    const natural = (stage.offsetHeight - stage.clientHeight) + status.offsetHeight + content + (cloud.hidden || collapsed ? 0 : cloud.offsetHeight)
      + queuedSlot.offsetHeight;
    held = frameTarget({ natural, held, cap: capPx(), holding, collapsed });
    if (held === null) frameFree();
    else frameTo(held, { animate: true });
  }
  const frameObserver = new ResizeObserver(() => fitFrame());
  for (const el of observed) frameObserver.observe(el);

  return {
    fitCap,
    frameFree,
    afterGrowth,
    easeStage,
    reveal,
    // A new turn, or none: no height held yet.
    resetHeld: () => { held = null; },
    // The tallest content seen is forgotten (a new turn, the cloud closed by hand).
    forgetContent: () => { maxContent = 0; },
  };
}
