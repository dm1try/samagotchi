// The stage view of a running turn (web.view: stage): the active turn pinned
// above the composer, its own card floating over the dock's (out of the
// dock's flow: its height never moves the composer). It shows only
// what happens now in fixed slots (a status row, the prompt, a two-line
// headline, the running tool, a one-line trail of the last calls), the
// cards and rows that arrive meanwhile in their own capped scroller, the
// answer, and a chip with one tick per tool call, the stage's footer (no
// content above it can push it away): the "cloud", the turn view's block
// (turn_view.js) reused as is, opens above it as the scroller's last slot,
// newest step first while the turn runs. When the turn has ended and the stage is not
// in use, everything moves into the history in the turn view's order (the
// hand-off), so a handed-off turn reads like the turn view's and like its
// reload. Slots are patched in place, never rebuilt from HTML: a selection
// and annotate survive. The rules are pure in stage_model.js.
import { createTurnView } from "./turn_view.js";
import { chipLabelText, flashOf, frameTarget, handOffDue, handOffOrder, headlineOf, inUseFrom, isPlain, liveSlots, MARKS, miniToolText, placeFor, placeKind, QUEUED_CHILDREN, stepSlotText } from "./stage_model.js";
import { createStageSlots, node } from "./stage_slots.js";
import { formatDuration } from "./timing.js";
import { easeScrollTo } from "./scroll.js";

const COLLAPSE_KEY = "chi_stage_collapsed";
const WATCH_MS = 200;
// The turn-end read (markdown, answer_display) settles within this, or the
// hand-off stops waiting for it.
const SETTLE_CAP_MS = 8000;
export const FOLD_MS = 420;
// The stage grows (a card, the long answer, the cloud opening) with a short
// ease: deliberate, never a snap.
const GROW_MS = 180;
const GROW_EASE = "cubic-bezier(.2,.7,.3,1)";
// The room between the stage and the composer card (index.html's margin-bottom).
const STAGE_GAP = 10;
const FLASH_MS = 4000;
// The answer reads from its top: at the end it is scrolled to unless this
// much of it (about three lines) shows already.
const ANSWER_SEEN = 72;
// A short answer cut by less than this at its foot isn't scrolled to.
const ANSWER_CUT = 12;
const PENDING = ".bubble.question:not(.answered):not(.cancelled), .bubble.continue:not(.resolved)";
// A running turn's card with actions (check-in's Nudge / Keep going / Stop)
// asks the user too, but the turn goes on: it waits only while the turn runs
// and never holds the hand-off (a turn cut short can leave it open).
const ASKS = ".plugin-card[data-in-turn] .card-action";

function reducedMotion() {
  return matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function readCollapsed() {
  try { return localStorage.getItem(COLLAPSE_KEY) === "1"; } catch (_) { return false; }
}

// +historyNearBottom+: the history's own follow check (the hand-off scrolls
// the history only for a reader at its end). +dockEl+, +centerEl+ and
// +composerEl+ size the stage's cap.
// +taskStop+: the page's stopper (task_stop.js), for the stop-task button
// on a running task_wait.
export function createStageView({ historyEl, appendToHistory, isNearBottom: historyNearBottom, sawText, sessionId, dockEl, centerEl, composerEl, taskStop = null }) {
  // The dock becomes a clear column: the stage's card, then the composer's
  // (its rows moved into .dock-card, which wears the glass and the focus ring).
  document.body.classList.add("stage-view");
  const card = node("div", "dock-card");
  card.append(...dockEl.children);
  dockEl.appendChild(card);
  const stage = node("section", "turn-stage");
  stage.id = "turnStage";
  stage.hidden = true;
  stage.setAttribute("aria-label", "Running turn");
  dockEl.prepend(stage);

  const status = node("div", "ts-status", stage);
  const mark = node("span", "ts-mark", status);
  const phaseEl = node("span", "ts-phase", status);
  const stepEl = node("span", "ts-step", status);
  const timingSlot = node("span", "ts-timing", status);
  const miniTool = node("span", "ts-mini", status);
  const defer = node("span", "ts-defer", status);
  defer.textContent = "moves up when you leave";
  const fold = node("button", "ts-fold", status);
  fold.type = "button";

  const scroller = node("div", "ts-scroll", stage);
  const promptSlot = node("div", "ts-prompt", scroller);
  promptSlot.title = "Show the whole prompt";
  const live = node("div", "ts-live", scroller);
  const headline = node("div", "ts-headline", live);
  headline.tabIndex = 0;
  headline.setAttribute("role", "button");
  headline.title = "Show this step's reasoning";
  // While a question or approval waits: the whole reply that asked it, in
  // the headline's place (the card says what to answer, this says why).
  const asking = node("div", "ts-asking", live);
  asking.hidden = true;
  const now = node("div", "ts-now", live);
  const trail = node("div", "ts-trail", live);
  const extras = node("div", "ts-extras", scroller);
  const answer = node("div", "ts-answer", scroller);
  const tail = node("div", "ts-tail", scroller);
  // The cloud's steps, the scroller's last slot, right above the chip.
  const cloudBody = node("div", "ts-cloud-body", scroller);
  cloudBody.hidden = true;
  // A 1 px mark at the tallest content's end (absolute: out of the flow),
  // so the scroll extent never drops while the turn runs: content that
  // shrinks never lowers a scrolled reader's scrollTop (the browser would
  // clamp it, moving everything in sight), even in the layout before
  // fitFrame runs.
  const holdEl = node("div", "ts-hold", scroller);
  holdEl.setAttribute("aria-hidden", "true");
  // The footer: the chip, pinned to the stage's bottom edge as the status
  // row is to its top.
  const cloud = node("div", "ts-foot", stage);
  const chip = node("button", "ts-chip", cloud);
  chip.type = "button";
  const chipLabel = node("span", "ts-chip-label", chip);
  const ticks = node("span", "ts-ticks", chip);
  // Below the turn's card: the lines queued for after it (placeKind
  // "queued"), each to run as a turn of its own; they hand off last.
  const queuedSlot = node("div", "ts-queued", stage);
  const slotsView = createStageSlots({
    headline, asking, now, trail, ticks, taskStop,
    gens: () => view.current().turn?.gens,
    onChange: () => scheduleRefresh(),
  });

  // The turn in the stage, from turnStarted until the hand-off (or a reset).
  let holding = false;
  let endKind = null;
  // The ended turn had no answer (turn_summary.empty_answer).
  let emptyAnswer = false;
  let settled = true;
  let settleTimer = null;
  let startedAt = 0;
  let endedAt = 0;
  let thinkingLine = null; // { step, text } from the live step's ticker
  let flash = null; // { kind, text, until } a notice or nudge in the trail
  let collapsed = readCollapsed();
  let cloudOpen = false;
  // A ref's "show in turn" opened a collapsed stage (not kept).
  let revealed = false;
  let rafPending = false;
  let foldTimer = null;
  let watchTimer = null;
  let quietSince = null;
  let pointerIn = false;
  let lastTouch = 0;
  // The frame (fitFrame): the height held while the turn runs and the
  // tallest content seen.
  let held = null;
  let maxContent = 0;
  let growth = null; // the running ease of the frame's growth (an Animation)
  let growthTo = 0; // its end height

  const view = createTurnView({
    historyEl,
    appendToHistory,
    sawText,
    sessionId,
    // The newest step is on top of the cloud: "near the bottom" is near its top.
    isNearBottom: () => cloudBody.scrollTop < 24,
    follow: () => { cloudBody.scrollTop = 0; },
    // The block goes into the cloud; a plain turn's (text, no thinking, no
    // tool, one step) streams in the answer slot until it turns out to be
    // more (refresh moves it).
    blockHost: (el) => cloudBody.appendChild(el),
    placeAnswer: (pieces, { plain, blockEl }) => {
      if (plain) blockEl.remove();
      answer.append(...pieces);
      showAnswerTop();
    },
    useHold: false,
    newestFirst: true,
    taskStop,
    onChange: () => scheduleRefresh(),
    onThinkingLine: (text) => {
      const { turn } = view.current();
      thinkingLine = { step: turn ? turn.gens.length : 0, text };
      scheduleRefresh();
    },
  });

  // ── slots ────────────────────────────────────────────────────────────────

  function scheduleRefresh() {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(refresh);
  }

  function pendingCard() {
    return !!(extras.querySelector(PENDING) || tail.querySelector(PENDING));
  }

  function asksCard() {
    return !endKind && !!extras.querySelector(ASKS);
  }
  // A card answered or redrawn in place (its buttons gone) changes the
  // status without a turn event: at once (a microtask), so the slots swap in
  // the card's own task, never a frame apart.
  new MutationObserver(() => refresh()).observe(extras, { childList: true, subtree: true });

  function refresh() {
    rafPending = false;
    const { turn, blockEl } = view.current();
    if (!holding || !turn) return;
    const gen = turn.gens[turn.gens.length - 1];
    // Plain once text streams without thinking or tools; until the first
    // chunk the live slots show (a slow first token leaves the height alone).
    const plain = !endKind && isPlain(turn) && !!gen?.text;
    if (blockEl && !endKind) {
      const host = plain ? answer : cloudBody;
      if (blockEl.parentNode !== host) host.appendChild(blockEl);
    }
    // The turn view closes its block at the end; the cloud shows its steps.
    if (blockEl && blockEl.parentNode === cloudBody) blockEl.open = true;
    const narration = gen?.text ? headlineOf(gen.text, gen.textDone || gen.closed) : "";
    const thinking = thinkingLine && thinkingLine.step === turn.gens.length ? thinkingLine.text : "";
    // A question blocks the turn: its card takes the live slots' room. An
    // asking card's turn goes on: the status waits, the slots stay.
    const blocked = pendingCard();
    const slots = liveSlots(turn, { narration, thinking, pending: blocked || asksCard(), blocked, ended: endKind, emptyAnswer });

    // The live slots keep their height while the turn waits and until its
    // next step (held-wait, set with waiting): the card under them never
    // moves at the answer. The waiting height is measured before the swap.
    const wasWaiting = stage.classList.contains("waiting");
    if (blocked && !wasWaiting) stage.classList.add("held-wait");
    if (!blocked && wasWaiting) stage.style.setProperty("--live-held", `${live.offsetHeight}px`);
    stage.classList.toggle("plain", plain);
    stage.classList.toggle("ended", !!endKind);
    stage.classList.toggle("waiting", blocked);
    stage.classList.toggle("asking", !!slots.asking);
    stage.dataset.phase = slots.phase;
    mark.textContent = MARKS[slots.phase] || "";
    phaseEl.textContent = slots.phase;

    slotsView.drawHeadline(slots.headline);
    slotsView.drawAsking(slots.asking);
    slotsView.drawNow(slots.tool, slots.quiet);
    slotsView.drawTrail(slots.trail, flash);
    slotsView.drawTicks(slots.ticks);
    const calls = slots.ticks.length;
    // An ended turn says each thing once: its steps in the chip (the label
    // of what the cloud holds), its time in the status row's timing line
    // (the one that moves into the history). The chip keeps the time when
    // that line is elsewhere (a turn the stage didn't hold from its start).
    const elapsed = endKind && !timingSlot.firstChild ? formatDuration(endedAt - startedAt) : "";
    chipLabel.textContent = chipLabelText({ steps: slots.step, calls, elapsed });
    const mini = miniToolText({ collapsed, tool: slots.tool });
    miniTool.textContent = mini.text;
    miniTool.title = mini.title;

    // An ended turn's live slots go, unless something under them would move
    // (a card or a row in the extras): then they stay as they were last.
    live.hidden = plain || (!!endKind && !extras.firstChild);
    cloud.hidden = !blockEl || blockEl.parentNode !== cloudBody;
    cloudBody.hidden = !cloudOpen || cloud.hidden;
    // Running: the step it is on. Ended: the count, unless the chip says it.
    stepEl.textContent = stepSlotText({ step: slots.step, ended: !!endKind, chipHidden: cloud.hidden });
    promptSlot.hidden = !promptSlot.firstChild;
    extras.hidden = !extras.firstChild;
    answer.hidden = !answer.firstChild;
    tail.hidden = !tail.firstChild;
  }

  // One line in the trail for FLASH_MS, ahead of the calls (a newer flash
  // takes its place).
  function flashTrail(what) {
    if (!what) return;
    flash = { ...what, until: Date.now() + FLASH_MS };
    scheduleRefresh();
    setTimeout(scheduleRefresh, FLASH_MS + 50);
  }

  // The answer reads from its top (no tail pin in the stage): scrolled to
  // (eased, once the stage has grown for it) when its top is out of sight
  // or only its first line shows.
  function showAnswerTop() {
    afterGrowth(() => {
      if (!answer.firstChild || answer.hidden || stage.hidden) return;
      const top = answer.offsetTop;
      const seen = scroller.scrollTop + scroller.clientHeight - top;
      if (top < scroller.scrollTop || seen < Math.min(answer.offsetHeight - ANSWER_CUT, ANSWER_SEEN)) easeStage(Math.max(0, top - 8));
    });
  }

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

  // ── collapse, cloud, peek ────────────────────────────────────────────────

  function applyCollapsed() {
    stage.classList.toggle("collapsed", collapsed);
    scroller.hidden = collapsed;
    fold.textContent = collapsed ? "▴" : "▾";
    fold.setAttribute("aria-label", collapsed ? "Expand the running turn" : "Collapse the running turn to its status");
    fold.setAttribute("aria-expanded", String(!collapsed));
    fitCap();
    scheduleRefresh();
  }

  function setCollapsed(value) {
    collapsed = value;
    revealed = false;
    try { localStorage.setItem(COLLAPSE_KEY, value ? "1" : "0"); } catch (_) {}
    applyCollapsed();
  }

  function setCloud(open) {
    cloudOpen = open;
    cloudBody.hidden = !open || cloud.hidden;
    // Closed by hand: its room isn't held at the scroller's end.
    if (!open) maxContent = 0;
    cloud.classList.toggle("open", open);
    stage.classList.toggle("cloud-open", open);
    chip.setAttribute("aria-expanded", String(open));
    fitCap();
    // The steps open right above the chip: in sight (the answer and the
    // cards above them scroll up), once the stage has grown for them.
    if (open) afterGrowth(() => reveal(cloudBody));
  }

  // Open the cloud at step +i+ (a hand toggle, as a click on its row), its
  // reasoning too with +thinking+.
  function openStep(i, { thinking = false } = {}) {
    const step = view.step(i);
    if (!step) return;
    if (collapsed) setCollapsed(false);
    setCloud(true);
    if (!step.el.open) step.summary.click();
    const wrap = step.thinkingWrap;
    if (thinking && wrap && !wrap.open) wrap.querySelector(":scope > summary")?.click();
    requestAnimationFrame(() => step.el.scrollIntoView({ block: "nearest" }));
  }

  function peek() {
    const { turn } = view.current();
    if (turn?.gens.length) openStep(turn.gens.length - 1, { thinking: true });
  }

  fold.addEventListener("click", (e) => {
    e.stopPropagation();
    setCollapsed(!collapsed);
  });
  status.addEventListener("click", (e) => {
    if (collapsed && !e.target.closest("button, a")) setCollapsed(false);
  });
  chip.addEventListener("click", (e) => {
    const tick = e.target.closest(".ts-tick");
    if (tick) openStep(Number(tick.dataset.step));
    else setCloud(!cloudOpen);
  });
  headline.addEventListener("click", peek);
  // A ref's "show in turn" (refs.js) names a row in the cloud: open the
  // stage and the cloud to it, as a hand toggle would.
  // A collapsed stage opens for this turn only: the kept choice
  // (chi_stage_collapsed) is left alone and comes back at the release.
  // The row's scroll into view (refs.js) waits for the stage's growth.
  // A row of a turn sliding away is no longer the stage's: it goes into the
  // history first (finishFold), and refs.js finds it there.
  stage.addEventListener("ref:reveal", (e) => {
    if (!cloudBody.contains(e.target)) return;
    if (folding) return finishFold();
    if (!holding) return;
    if (collapsed) {
      collapsed = false;
      revealed = true;
      applyCollapsed();
    }
    setCloud(true);
    if (e.detail) e.detail.until = new Promise((resolve) => afterGrowth(resolve));
  });
  headline.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      peek();
    }
  });
  promptSlot.addEventListener("click", (e) => {
    if (e.target.closest("button, a, img")) return;
    if (window.getSelection()?.isCollapsed === false) return;
    promptSlot.classList.toggle("full");
  });

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
    const share = window.innerHeight * (cloudOpen ? 0.8 : 0.6);
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
    const ease = animate && px > from && !collapsed && !stage.hidden && !document.hidden && !reducedMotion();
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
  for (const el of [status, promptSlot, live, extras, answer, tail, cloudBody, cloud, queuedSlot]) frameObserver.observe(el);

  // ── in use: pointer over it (tracked on the stage itself: :hover goes
  // stale when children change), a touch or wheel in the last 4 s (phones
  // have no hover), keyboard focus or a selection in it ─────────────────

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
      if (!holding || !endKind) return stopWatch();
      const nowMs = Date.now();
      const busy = inUse(nowMs);
      stage.classList.toggle("in-use", busy);
      const r = handOffDue({ ended: true, pending: !settled || pendingCard(), inUse: busy, quietSinceMs: quietSince, nowMs });
      quietSince = r.quietSinceMs;
      if (r.due) handOff();
    }, WATCH_MS);
  }

  // ── show, clear, hand off ────────────────────────────────────────────────

  // A fold cut short (the stage shows again): the slide's class goes.
  function cancelFold() {
    clearTimeout(foldTimer);
    foldTimer = null;
    stage.classList.remove("leaving");
  }

  function show() {
    cancelFold();
    const hidden = stage.hidden;
    stage.hidden = false;
    applyCollapsed();
    if (hidden && !reducedMotion()) {
      stage.classList.remove("enter");
      void stage.offsetWidth;
      stage.classList.add("enter");
    }
  }

  function emptySlots() {
    for (const slot of [promptSlot, extras, answer, tail, cloudBody, queuedSlot, timingSlot]) slot.replaceChildren();
    slotsView.reset();
    promptSlot.classList.remove("full");
    thinkingLine = null;
    flash = null;
    setCloud(false);
    stage.classList.remove("plain", "ended", "waiting", "held-wait", "asking", "in-use");
    stage.style.removeProperty("--live-held");
  }

  // The turn leaves the stage's care (the hand-off's start, a reset, a new
  // turn): from here new rows, the next timing line and the history's
  // scroll are the history's (place, timingHost, holds). The slots keep
  // what they show until clearStage.
  function releaseTurn() {
    stopWatch();
    clearTimeout(settleTimer);
    holding = false;
    held = null;
    endKind = null;
    emptyAnswer = false;
    settled = true;
    view.reset();
  }

  // The stage empty and hidden, its frame free.
  function clearStage() {
    cancelFold();
    emptySlots();
    stage.hidden = true;
    frameFree();
    if (revealed) {
      revealed = false;
      collapsed = readCollapsed();
      applyCollapsed();
    }
  }

  function release() {
    releaseTurn();
    clearStage();
  }

  // The hand-off: everything the stage holds goes into the history's end in
  // the turn view's order (prompt, block (chronological; its outline open,
  // else collapsed), extras, answer, timing line, then the end line and
  // what came after the end). The turn is released at once; the stage
  // slides away under the composer still drawn (a transform: nothing on the
  // page moves; app.js eases the history's bottom reserve meanwhile), then
  // the pieces arrive in the history and it follows a reader who was at its
  // end. Not with +immediate+ (another turn takes the stage at once), a
  // reduced motion, a hidden page or a collapsed stage: all at once.
  let folding = null; // { pieces, block, wasAtEnd, animate } while it slides
  function handOff({ immediate = false } = {}) {
    if (folding && immediate) finishFold();
    if (!holding || !endKind) return;
    const { blockEl } = view.current();
    view.chronological();
    const block = blockEl && blockEl.parentNode === cloudBody ? blockEl : null;
    const pieces = handOffOrder({
      prompt: promptSlot.firstElementChild,
      block,
      extras: [...extras.children],
      answer: [...answer.children],
      timing: timingSlot.firstElementChild,
      kept: [...tail.children],
      queued: [...queuedSlot.children],
    });
    const animate = !immediate && !reducedMotion() && !document.hidden && !collapsed;
    folding = { pieces, block: blockEl, wasAtEnd: historyNearBottom(), animate };
    releaseTurn();
    if (!animate) return finishFold();
    stage.classList.add("leaving");
    foldTimer = setTimeout(finishFold, FOLD_MS);
  }

  // The fold's end (or a cut-short fold): the original pieces (their ref
  // bindings, selection and late updates with them) move into the history.
  function finishFold() {
    const fold = folding;
    if (!fold) return;
    folding = null;
    // Closed, unless it is an outline (turn_view.js outlineBlock): the
    // history reads its narrated steps without a click.
    if (fold.block) fold.block.open = fold.block.classList.contains("outline");
    historyEl.querySelector(":scope > .hint")?.remove();
    for (const el of fold.pieces) {
      historyEl.appendChild(el);
      if (fold.animate) {
        el.classList.add("ts-arrive");
        el.addEventListener("animationend", () => el.classList.remove("ts-arrive"), { once: true });
      }
    }
    clearStage();
    if (fold.wasAtEnd) easeScrollTo(historyEl, () => historyEl.scrollHeight - historyEl.clientHeight, { reduce: !fold.animate || reducedMotion() });
  }

  // ── the view interface (app.js) ──────────────────────────────────────────

  return {
    turnStarted(data) {
      if (folding) finishFold();
      // A turn that never ended (released, not handed off) leaves its queued
      // lines waiting still: they stay.
      const waiting = [...queuedSlot.children].filter((el) => el !== data?.promptBubble);
      if (holding) {
        if (endKind) handOff({ immediate: true });
        else release();
      }
      holding = true;
      held = null;
      maxContent = 0;
      endKind = null;
      emptyAnswer = false;
      settled = true;
      startedAt = Date.parse(data?.started_at) || Date.now();
      emptySlots();
      // The turn's prompt bubble (app.js found or drew it) sits in the prompt
      // line until the hand-off takes it back first.
      if (data?.promptBubble) promptSlot.appendChild(data.promptBubble);
      // The lines still queued behind this turn went into the history with
      // the turn before (the hand-off at this turn_started, or an earlier
      // one): back below this turn's card, as a reload places them.
      queuedSlot.append(...waiting.filter((el) => !el.isConnected), ...historyEl.querySelectorAll(QUEUED_CHILDREN));
      view.turnStarted(data || {});
      show();
      refresh();
    },
    generationStarted(data, now = null) {
      // The next step: the live slots' waiting height is let go.
      stage.classList.remove("held-wait");
      stage.style.removeProperty("--live-held");
      view.generationStarted(data, now);
    },
    chunk: (data) => view.chunk(data),
    generationRestarted: (data) => view.generationRestarted(data),
    generationCompleted: () => view.generationCompleted(),
    toolStarted: (data) => view.toolStarted(data),
    toolCompleted: (data) => view.toolCompleted(data),
    turnEnded(args) {
      const kept = view.turnEnded(args) || [];
      if (!holding) return kept;
      // The warn cards the extras kept in sight leave the turn with the
      // block's (card.js leavesBlock): after the end line, as a reload has them.
      const warn = [...extras.querySelectorAll(":scope > .plugin-card.warn")];
      warn.forEach((el) => el.remove());
      kept.push(...warn);
      view.chronological();
      endKind = args.kind;
      emptyAnswer = !!args.emptyAnswer;
      endedAt = Date.now();
      // A completed turn's end read (markdown, answer_display) is pending
      // until answerReady; the others have none.
      settled = args.kind !== "completed";
      clearTimeout(settleTimer);
      if (!settled) settleTimer = setTimeout(() => { settled = true; }, SETTLE_CAP_MS);
      refresh();
      startWatch();
      return kept;
    },
    // A hook's notice and a plugin's nudge go into their step inside the
    // closed cloud; they flash in the trail meanwhile (flashOf).
    notice(data) {
      const placed = view.notice(data);
      if (placed) flashTrail(flashOf("notice", data));
      return placed;
    },
    steer(data) {
      const placed = view.steer(data);
      if (placed) flashTrail(flashOf("steer", data));
      return placed;
    },
    // A warn card (a plugin's warning) stays in sight: false puts it in the
    // extras (place), not in its step inside the closed cloud.
    card: (el) => !el.classList.contains("warn") && view.card(el),
    flush: () => view.flush(),
    answerReady() {
      settled = true;
      clearTimeout(settleTimer);
      view.answerReady();
    },
    containsLive: (el) => view.containsLive(el),
    askingText: () => view.askingText(),
    // The turn model and its live phase as the status row reads it (the
    // composer's delivery line).
    current: () => view.current(),
    phase: () => liveSlots(view.current().turn, { pending: pendingCard() || asksCard() }).phase,
    reset() {
      if (folding) finishFold();
      release();
    },
    // The stage's extras while it holds a turn (a card, a prompt for its
    // next step, a command, a note, the end line), its queued slot for a
    // line queued for after it; false: the history takes it.
    place(el) {
      // A turn still sliding away goes into the history first: what comes
      // now comes after it.
      if (folding) finishFold();
      const where = placeFor({ live: holding, handingOff: false, kind: placeKind(el) });
      if (where === "history") return false;
      if (where === "queued") {
        queuedSlot.appendChild(el);
        scheduleRefresh();
        return true;
      }
      const slot = endKind ? tail : extras;
      const stick = slot.scrollHeight - slot.scrollTop - slot.clientHeight < 24;
      slot.appendChild(el);
      slot.hidden = false;
      const waits = el.matches?.(PENDING) || el.querySelector?.(ASKS);
      if (stick || waits) slot.scrollTop = slot.scrollHeight;
      // A waiting card and the asking text (refresh) land in one task.
      if (waits) refresh();
      else scheduleRefresh();
      // A card that waits for the user is brought into the stage's view: in
      // a short window the prompt and headline fill it and the card sat
      // below, out of sight (once the stage has grown for it).
      if (waits) afterGrowth(() => reveal(slot));
      return true;
    },
    // Where the live timing line goes (the status row), null: the history.
    timingHost: () => {
      if (folding) finishFold();
      return holding ? timingSlot : null;
    },
    // Before anything else goes into the history (app.js): a turn still
    // sliding away gets there first.
    settleFold: () => { if (folding) finishFold(); },
    // A turn is in the stage (running, or ended and not handed off yet):
    // nothing the turn does touches the history's scroll.
    holds: () => holding,
    handOff,
    root: stage,
    scrollEl: scroller,
  };
}
