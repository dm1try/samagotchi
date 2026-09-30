// The stage view of a running turn (web.view: stage): the active turn pinned
// above the composer, as the top section of the dock card. It shows only
// what happens now in fixed slots (a status row, the prompt, a two-line
// headline, the running tool, a one-line trail of the last calls), the
// cards and rows that arrive meanwhile in their own capped scroller, the
// answer, and a chip with one tick per tool call: the "cloud", the turn
// view's block (turn_view.js) reused as is, expands in place, newest step
// first while the turn runs. When the turn has ended and the stage is not
// in use, everything moves into the history in the turn view's order (the
// hand-off), so a handed-off turn reads like the turn view's and like its
// reload. Slots are patched in place, never rebuilt from HTML: a selection
// and annotate survive. The rules are pure in stage_model.js.
import { createTurnView } from "./turn_view.js";
import { flashOf, handOffDue, handOffOrder, headlineOf, inUseFrom, isPlain, liveSlots, placeFor } from "./stage_model.js";
import { formatDuration } from "./timing.js";

const COLLAPSE_KEY = "chi_stage_collapsed";
const WATCH_MS = 200;
// The turn-end read (markdown, answer_display) settles within this, or the
// hand-off stops waiting for it.
const SETTLE_CAP_MS = 8000;
const FOLD_MS = 420;
const FLASH_MS = 4000;
const PENDING = ".bubble.question:not(.answered):not(.cancelled), .bubble.continue:not(.resolved)";
// A running turn's card with actions (check-in's Nudge / Keep going / Stop)
// asks the user too, but the turn goes on: it waits only while the turn runs
// and never holds the hand-off (a turn cut short can leave it open).
const ASKS = ".plugin-card[data-in-turn] .card-action";
const MARKS = { answered: "✓", canceled: "■", failed: "✕" };
// The mark of a flash in the trail: a warn notice, a hook's info notice, a
// plugin's nudge (steer).
const FLASH_MARKS = { warn: "⚠", info: "ℹ", steer: "↪" };

function node(tag, cls, parent = null) {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (parent) parent.appendChild(el);
  return el;
}

function readCollapsed() {
  try { return localStorage.getItem(COLLAPSE_KEY) === "1"; } catch (_) { return false; }
}

// +historyNearBottom+: the history's own follow check (the hand-off scrolls
// the history only for a reader at its end). +dockEl+, +centerEl+ and
// +composerEl+ size the stage's cap.
export function createStageView({ historyEl, appendToHistory, isNearBottom: historyNearBottom, sawText, sessionId, dockEl, centerEl, composerEl }) {
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
  const now = node("div", "ts-now", live);
  const trail = node("div", "ts-trail", live);
  const extras = node("div", "ts-extras", scroller);
  const answer = node("div", "ts-answer", scroller);
  const tail = node("div", "ts-tail", scroller);
  const cloud = node("div", "ts-cloud", scroller);
  const chip = node("button", "ts-chip", cloud);
  chip.type = "button";
  const chipLabel = node("span", "ts-chip-label", chip);
  const ticks = node("span", "ts-ticks", chip);
  const cloudBody = node("div", "ts-cloud-body", cloud);
  cloudBody.hidden = true;

  // The turn in the stage, from turnStarted until the hand-off (or a reset).
  let holding = false;
  let endKind = null;
  let settled = true;
  let settleTimer = null;
  let startedAt = 0;
  let endedAt = 0;
  let thinkingLine = null; // { step, text } from the live step's ticker
  let flash = null; // { kind, text, until } a notice or nudge in the trail
  let collapsed = readCollapsed();
  let cloudOpen = false;
  let rafPending = false;
  let foldTimer = null;
  let watchTimer = null;
  let quietSince = null;
  let pointerIn = false;
  let lastTouch = 0;
  // What each slot shows, so an unchanged slot is left alone.
  const shown = { headline: null, now: null, trail: null };

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
  // status without a turn event.
  new MutationObserver(() => scheduleRefresh()).observe(extras, { childList: true, subtree: true });

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
    const slots = liveSlots(turn, { narration, thinking, pending: blocked || asksCard(), ended: endKind });

    stage.classList.toggle("plain", plain);
    stage.classList.toggle("ended", !!endKind);
    stage.classList.toggle("waiting", blocked);
    stage.dataset.phase = slots.phase;
    mark.textContent = MARKS[slots.phase] || "";
    phaseEl.textContent = slots.phase;
    stepEl.textContent = endKind ? `${slots.step} step${slots.step === 1 ? "" : "s"}` : `step ${slots.step}`;

    drawHeadline(slots.headline);
    drawNow(slots.tool, gen);
    drawTrail(slots.trail);
    drawTicks(slots.ticks);
    const calls = slots.ticks.length;
    const elapsed = endKind ? formatDuration(endedAt - startedAt) : "";
    chipLabel.textContent = `${slots.step} step${slots.step === 1 ? "" : "s"} · ${calls} tool call${calls === 1 ? "" : "s"}${elapsed ? ` · ${elapsed}` : ""}`;
    miniTool.textContent = collapsed && slots.tool ? `${slots.tool.name} ${slots.tool.title}` : "";

    live.hidden = plain || !!endKind;
    cloud.hidden = !blockEl || blockEl.parentNode !== cloudBody;
    promptSlot.hidden = !promptSlot.firstChild;
    extras.hidden = !extras.firstChild;
    answer.hidden = !answer.firstChild;
    tail.hidden = !tail.firstChild;
  }

  function drawHeadline({ text, thinking }) {
    const key = `${thinking ? "t" : "n"}|${text}`;
    if (shown.headline === key) return;
    shown.headline = key;
    headline.replaceChildren();
    headline.classList.toggle("thinking", thinking);
    if (thinking) {
      const tag = node("span", "ts-think-tag", headline);
      tag.textContent = "thinking";
    }
    headline.appendChild(document.createTextNode(text));
    headline.classList.remove("fresh");
    void headline.offsetWidth;
    headline.classList.add("fresh");
  }

  function drawNow(tool, gen) {
    const quiet = gen?.text && !gen.textDone ? "writing…" : "thinking…";
    const key = tool ? `run|${tool.name}|${tool.title}` : `quiet|${quiet}`;
    if (shown.now === key) return;
    shown.now = key;
    now.replaceChildren();
    now.classList.toggle("running", !!tool);
    node("span", tool ? "ts-spin" : "ts-idle", now);
    if (tool) {
      const name = node("span", `ts-tool ${tool.kind}`, now);
      name.textContent = tool.name;
      const title = node("span", "ts-title", now);
      title.textContent = tool.title;
      title.title = tool.title;
    } else {
      const word = node("span", "ts-title quiet", now);
      word.textContent = quiet;
    }
  }

  function drawTrail(items) {
    const flashing = flash && flash.until > Date.now() ? flash : null;
    const key = JSON.stringify([flashing?.kind, flashing?.text, items]);
    if (shown.trail === key) return;
    shown.trail = key;
    trail.replaceChildren();
    if (flashing) node("span", `ts-trail-item ${flashing.kind}`, trail).textContent = `${FLASH_MARKS[flashing.kind]} ${flashing.text}`;
    for (const item of items) {
      const failed = item.status === "error";
      const el = node("span", `ts-trail-item${failed ? " error" : ""}`, trail);
      el.textContent = `${failed ? "✕" : "✓"} ${item.name} ${item.title}`.trim();
    }
    if (!flashing && !items.length) node("span", "ts-trail-item none", trail).textContent = "no tool calls yet";
  }

  // One line in the trail for FLASH_MS, ahead of the calls (a newer flash
  // takes its place).
  function flashTrail(what) {
    if (!what) return;
    flash = { ...what, until: Date.now() + FLASH_MS };
    scheduleRefresh();
    setTimeout(scheduleRefresh, FLASH_MS + 50);
  }

  function drawTicks(list) {
    list.forEach((tick, i) => {
      let el = ticks.children[i];
      if (!el) {
        el = node("span", "", ticks);
        el.setAttribute("role", "button");
      }
      const cls = `ts-tick ${tick.kind} ${tick.status}`;
      if (el.className !== cls) el.className = cls;
      el.dataset.step = String(tick.step);
      el.title = `step ${tick.step + 1}`;
    });
    while (ticks.children.length > list.length) ticks.lastChild.remove();
  }

  // The answer reads from its top (no tail pin in the stage).
  function showAnswerTop() {
    requestAnimationFrame(() => {
      if (answer.firstChild) scroller.scrollTop = Math.max(0, answer.offsetTop - 8);
    });
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
    try { localStorage.setItem(COLLAPSE_KEY, value ? "1" : "0"); } catch (_) {}
    applyCollapsed();
  }

  function setCloud(open) {
    cloudOpen = open;
    cloudBody.hidden = !open;
    cloud.classList.toggle("open", open);
    stage.classList.toggle("cloud-open", open);
    chip.setAttribute("aria-expanded", String(open));
    fitCap();
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

  function fitCap() {
    if (stage.hidden) return;
    const rest = dockEl.offsetHeight - stage.offsetHeight;
    const room = centerEl.clientHeight - rest - 32;
    const share = window.innerHeight * (cloudOpen ? 0.8 : 0.6);
    stage.style.setProperty("--stage-max", `${Math.max(96, Math.round(Math.min(share, room)))}px`);
  }
  new ResizeObserver(() => fitCap()).observe(centerEl);
  new ResizeObserver(() => fitCap()).observe(composerEl);
  window.addEventListener("resize", fitCap);

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

  function cancelFold() {
    clearTimeout(foldTimer);
    foldTimer = null;
    stage.classList.remove("leaving");
    stage.style.height = "";
  }

  function show() {
    cancelFold();
    const hidden = stage.hidden;
    stage.hidden = false;
    applyCollapsed();
    if (hidden && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      stage.classList.remove("enter");
      void stage.offsetWidth;
      stage.classList.add("enter");
    }
  }

  function emptySlots() {
    for (const slot of [promptSlot, extras, answer, tail, cloudBody, timingSlot, headline, now, trail, ticks]) slot.replaceChildren();
    promptSlot.classList.remove("full");
    shown.headline = shown.now = shown.trail = null;
    thinkingLine = null;
    flash = null;
    setCloud(false);
    stage.classList.remove("plain", "ended", "waiting", "in-use");
  }

  function release() {
    stopWatch();
    clearTimeout(settleTimer);
    holding = false;
    endKind = null;
    settled = true;
    view.reset();
    emptySlots();
  }

  // Everything the stage holds, into the history's end in the turn view's
  // order: prompt, block (collapsed, chronological), extras, answer, timing
  // line, then the end line and what came after the end. The stage folds
  // away while the turn fades up into the history (not with +immediate+:
  // another turn takes the stage at once). The history follows only a
  // reader who was at its end.
  function handOff({ immediate = false } = {}) {
    if (!holding || !endKind) return;
    const { blockEl } = view.current();
    view.chronological();
    if (blockEl) blockEl.open = false;
    const wasAtEnd = historyNearBottom();
    const pieces = handOffOrder({
      prompt: promptSlot.firstElementChild,
      block: blockEl && blockEl.parentNode === cloudBody ? blockEl : null,
      extras: [...extras.children],
      answer: [...answer.children],
      timing: timingSlot.firstElementChild,
      kept: [...tail.children],
    });
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const animate = !immediate && !reduce && !document.hidden && !collapsed;
    if (animate) {
      stage.style.height = `${stage.offsetHeight}px`;
      void stage.offsetHeight;
    }
    historyEl.querySelector(":scope > .hint")?.remove();
    for (const el of pieces) {
      historyEl.appendChild(el);
      if (animate) {
        el.classList.add("ts-arrive");
        el.addEventListener("animationend", () => el.classList.remove("ts-arrive"), { once: true });
      }
    }
    release();
    if (!animate) {
      stage.hidden = true;
      if (wasAtEnd) historyEl.scrollTop = historyEl.scrollHeight;
      return;
    }
    stage.classList.add("leaving");
    stage.style.height = "0px";
    if (wasAtEnd) historyEl.scrollTo({ top: historyEl.scrollHeight, behavior: "smooth" });
    foldTimer = setTimeout(() => {
      cancelFold();
      stage.hidden = true;
      if (wasAtEnd) historyEl.scrollTo({ top: historyEl.scrollHeight, behavior: "smooth" });
    }, FOLD_MS);
  }

  // ── the view interface (app.js) ──────────────────────────────────────────

  return {
    turnStarted(data) {
      if (holding) {
        if (endKind) handOff({ immediate: true });
        else release();
      }
      holding = true;
      endKind = null;
      settled = true;
      startedAt = Date.parse(data?.started_at) || Date.now();
      emptySlots();
      // The turn's prompt bubble (app.js found or drew it) sits in the prompt
      // line until the hand-off takes it back first.
      if (data?.promptBubble) promptSlot.appendChild(data.promptBubble);
      view.turnStarted(data || {});
      show();
      refresh();
    },
    generationStarted: (data) => view.generationStarted(data),
    chunk: (data) => view.chunk(data),
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
    reset() {
      cancelFold();
      release();
      stage.hidden = true;
    },
    // The stage's extras while it holds a turn (a card, a queued prompt, a
    // command, a note, the end line); false: the history takes it.
    place(el) {
      const kind = el.matches?.(".bubble.recap") ? "recap" : "row";
      if (placeFor({ live: holding, handingOff: false, kind }) !== "stage") return false;
      const slot = endKind ? tail : extras;
      const stick = slot.scrollHeight - slot.scrollTop - slot.clientHeight < 24;
      slot.appendChild(el);
      slot.hidden = false;
      if (stick || el.matches?.(PENDING) || el.querySelector?.(ASKS)) slot.scrollTop = slot.scrollHeight;
      scheduleRefresh();
      return true;
    },
    // Where the live timing line goes (the status row), null: the history.
    timingHost: () => (holding ? timingSlot : null),
    // A turn is in the stage (running, or ended and not handed off yet):
    // nothing the turn does touches the history's scroll.
    holds: () => holding,
    handOff,
    root: stage,
    scrollEl: scroller,
  };
}
