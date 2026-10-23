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
// and annotate survive. The rules are pure in stage_model.js; the live
// slots are drawn by stage_slots.js, the cap and the held height are
// stage_frame.js's, and the in-use watch that times the hand-off is
// stage_watch.js's.
import { createTurnView } from "./turn_view.js";
import { chipLabelText, flashOf, handOffDue, handOffOrder, headlineOf, isPlain, liveSlots, MARKS, miniToolText, placeFor, placeKind, QUEUED_CHILDREN, stepSlotText } from "./stage_model.js";
import { createStageSlots, node } from "./stage_slots.js";
import { createStageFrame, reducedMotion } from "./stage_frame.js";
import { createInUseWatch } from "./stage_watch.js";
import { formatDuration } from "./timing.js";
import { easeScrollTo } from "./scroll.js";
import { readStored, writeStored } from "./storage.js";
import { createWorkingSetRail } from "./working_set_rail.js";
import { stampRows } from "./working_set_view.js";

const COLLAPSE_KEY = "chi_stage_collapsed";
// The turn-end read (markdown, answer_display) settles within this, or the
// hand-off stops waiting for it.
const SETTLE_CAP_MS = 8000;
export const FOLD_MS = 420;
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
// The model's own question (question_cards.js data-kind; not an approval,
// the step limit, a hook's question or a delegate's relayed one): the one
// card whose long asking text gets the question room.
const ASK_CARD = '.bubble.question[data-kind="question"]:not([data-relay])';

function readCollapsed() {
  return readStored(COLLAPSE_KEY) === "1";
}

// +historyNearBottom+: the history's own follow check (the hand-off scrolls
// the history only for a reader at its end). +dockEl+, +centerEl+ and
// +composerEl+ size the stage's cap.
// +taskStop+: the page's stopper (task_stop.js), for the stop-task button
// on a running task_wait. +renderMarkdown+ and +linkRefs+: the asking
// slot's markdown read and ref pass (stage_slots.js). +workingSet+: the
// page's working set (working_set_view.js, web.working_set; null: off): its
// rail in the live slots, its footprint at the hand-off.
export function createStageView({
  historyEl, appendToHistory, isNearBottom: historyNearBottom, sawText, sessionId, dockEl, centerEl, composerEl, taskStop = null,
  renderMarkdown, linkRefs, workingSet = null,
}) {
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
  // the headline's place (the card says what to answer, this says why),
  // as markdown when web.markdown is on.
  const asking = node("div", "ts-asking", live);
  asking.hidden = true;
  const now = node("div", "ts-now", live);
  const trail = node("div", "ts-trail", live);
  // The working set's rail: out of the live slots' flow on their right (a
  // row under the trail in a narrow stage), so it never sets their height.
  const rail = workingSet
    ? createWorkingSetRail({ live, stage, onOpen: (el) => workingSet.openTurn(el), onChange: () => scheduleRefresh() })
    : null;
  if (rail) {
    workingSet.setSeen(rail.seenAt);
    // The server's states change the lines (never the fold): a redraw.
    workingSet.onServer(() => scheduleRefresh());
  }
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
  // The question room's jump pill, at the scroller's bottom edge (absolute,
  // above the chip): while the room's card is out of the stage's view it
  // eases the stage to it (drawPill).
  const pill = node("button", "ts-room-pill", cloud);
  pill.type = "button";
  pill.setAttribute("aria-label", "Go to the question");
  pill.hidden = true;
  pill.textContent = "❓ Answer ↓";
  // Below the turn's card: the lines queued for after it (placeKind
  // "queued"), each to run as a turn of its own; they hand off last.
  const queuedSlot = node("div", "ts-queued", stage);
  const slotsView = createStageSlots({
    headline, asking, now, trail, ticks, taskStop, renderMarkdown, linkRefs,
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
  let flashTimer = null; // its end's redraw
  let collapsed = readCollapsed();
  let cloudOpen = false;
  // A ref's "show in turn" opened a collapsed stage (not kept).
  let revealed = false;
  let rafPending = false;
  let foldTimer = null;
  // The question room (drawRoom): the pending ask card whose asking text
  // overflowed its cap, and the turn's raised cap (stage_frame.js; kept
  // until the next turn: the frame is grow-only).
  let roomCard = null;
  let roomCap = false;
  // What the overflow was measured for ({ card, text }): measured once the
  // asking text shows in its final form (its markdown, or the raw text when
  // there is none: the raw text is taller, and a short question's could
  // overflow where its markdown fits), again only for a new card or text,
  // never at a cap's change (a phone's keyboard).
  let measured = null;
  // The ask card whose arrival reveal has run (no pill while the stage
  // grows to it), and whether the room's card is in the stage's view.
  let arrived = null;
  let cardInSight = true;

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

  // The pending card in the extras when it is the model's own question
  // (never the tail's: a post-end card, the step limit; asking is empty then).
  function askCard() {
    const card = extras.querySelector(PENDING);
    return card?.matches(ASK_CARD) ? card : null;
  }

  // The asking text overflows its cap (+1 px of rounding), measured with
  // the room's class off.
  function askingOverflows() {
    return !asking.hidden && asking.scrollHeight > asking.clientHeight + 1;
  }

  // The question room: while a model's own question waits and its asking
  // text didn't fit its cap, the slot loses its cap and the stage's one
  // scroll reads the whole reply (index.html .question-room); the cap rises
  // for the rest of the turn. The card keeps the room until it stops
  // pending (+text+: the asking text drawn).
  function drawRoom(blocked, text) {
    const ask = blocked ? askCard() : null;
    if (roomCard && ask === roomCard) return;
    if (roomCard) {
      cardSight.unobserve(roomCard);
      stage.classList.remove("question-room");
      roomCard = null;
    }
    if (!ask || !slotsView.askingSettled() || (measured && measured.card === ask && measured.text === text)) return;
    measured = { card: ask, text };
    if (!askingOverflows()) return;
    roomCard = ask;
    stage.classList.add("question-room");
    cardInSight = true;
    cardSight.observe(roomCard);
    if (!roomCap) {
      roomCap = true;
      frame.fitCap();
    }
    // Decided after the card's arrival reveal (a slow markdown read): the
    // reply reads from its start now, the pill only after that.
    if (arrived === ask) {
      arrived = null;
      frame.afterGrowth(() => {
        if (roomCard !== ask) return;
        frame.reveal(extras, { fromStart: true });
        arrived = ask;
        drawPill();
      });
    }
  }

  // The pill: the room's card out of the stage's view, once its arrival
  // reveal has run, the stage open.
  function drawPill() {
    pill.hidden = !(roomCard && !collapsed && arrived === roomCard && !cardInSight);
  }

  // The room's card in the stage's view: ~40 px of it shows above the
  // scroller's bottom edge (where the pill sits).
  const cardSight = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.target === roomCard) cardInSight = entry.isIntersecting;
    drawPill();
  }, { root: scroller, rootMargin: "0px 0px -40px 0px", threshold: 0 });

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
    if (blocked && !wasWaiting) {
      stage.classList.add("held-wait");
      live.style.minHeight = "";
    }
    if (!blocked && wasWaiting) stage.style.setProperty("--live-held", `${live.offsetHeight}px`);
    stage.classList.toggle("plain", plain);
    stage.classList.toggle("ended", !!endKind);
    stage.classList.toggle("waiting", blocked);
    stage.classList.toggle("asking", !!slots.asking);
    stage.dataset.phase = slots.phase;
    mark.textContent = MARKS[slots.phase] || "";
    phaseEl.textContent = slots.phase;

    slotsView.drawHeadline(slots.headline);
    slotsView.drawAsking(slots.asking, slots.askingRefs);
    drawRoom(blocked, slots.asking);
    drawPill();
    slotsView.drawNow(slots.tool, slots.quiet);
    slotsView.drawTrail(slots.trail, flash);
    slotsView.drawTicks(slots.ticks);
    if (rail) {
      const { items, ordinal } = workingSet.liveItems(turn, promptWords());
      stampRows(blockEl, turn, ordinal);
      rail.draw(items, { ctxPct: workingSet.ctxPct(), pending: workingSet.pending() });
    }
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

  // The prompt's first words (the working set's session tags say whose
  // turn a step was).
  function promptWords() {
    const text = (promptSlot.querySelector(".user-message")?.textContent || "").replace(/\s+/g, " ").trim();
    return text.length > 60 ? `${text.slice(0, 59)}\u2026` : text;
  }

  // The next step: the live slots' waiting height is let go. In a turn
  // with the question room that height was the whole reply's: it goes as
  // far as the stage's scroll absorbs it (the scroll moves up by as much,
  // in the same task: the card in view stays put), the rest kept as the
  // live slots' least height until the next wait or turn.
  function releaseHeldWait() {
    const held = roomCap && stage.classList.contains("held-wait") && !stage.classList.contains("waiting");
    const before = held ? live.offsetHeight : 0;
    const top = scroller.scrollTop;
    stage.classList.remove("held-wait");
    stage.style.removeProperty("--live-held");
    live.style.minHeight = "";
    if (!held) return;
    const after = live.offsetHeight;
    const absorbed = Math.min(Math.max(0, before - after), top);
    if (before - absorbed > after) live.style.minHeight = `${before - absorbed}px`;
    if (absorbed) scroller.scrollTop = top - absorbed;
  }

  // One line in the trail for FLASH_MS, ahead of the calls (a newer flash
  // takes its place).
  function flashTrail(what) {
    if (!what) return;
    flash = { ...what, until: Date.now() + FLASH_MS };
    scheduleRefresh();
    clearTimeout(flashTimer);
    flashTimer = setTimeout(scheduleRefresh, FLASH_MS + 50);
  }

  // The answer reads from its top (no tail pin in the stage): scrolled to
  // (eased, once the stage has grown for it) when its top is out of sight
  // or only its first line shows.
  function showAnswerTop() {
    frame.afterGrowth(() => {
      if (!answer.firstChild || answer.hidden || stage.hidden) return;
      const top = answer.offsetTop;
      const seen = scroller.scrollTop + scroller.clientHeight - top;
      if (top < scroller.scrollTop || seen < Math.min(answer.offsetHeight - ANSWER_CUT, ANSWER_SEEN)) frame.easeStage(Math.max(0, top - 8));
    });
  }

  // ── collapse, cloud, peek ────────────────────────────────────────────────

  function applyCollapsed() {
    stage.classList.toggle("collapsed", collapsed);
    scroller.hidden = collapsed;
    fold.textContent = collapsed ? "▴" : "▾";
    fold.setAttribute("aria-label", collapsed ? "Expand the running turn" : "Collapse the running turn to its status");
    fold.setAttribute("aria-expanded", String(!collapsed));
    frame.fitCap();
    scheduleRefresh();
  }

  function setCollapsed(value) {
    collapsed = value;
    revealed = false;
    writeStored(COLLAPSE_KEY, value ? "1" : "0");
    applyCollapsed();
  }

  function setCloud(open) {
    cloudOpen = open;
    cloudBody.hidden = !open || cloud.hidden;
    // Closed by hand: its room isn't held (the stage shrinks back to what
    // shows).
    if (!open) frame.forgetContent();
    cloud.classList.toggle("open", open);
    stage.classList.toggle("cloud-open", open);
    chip.setAttribute("aria-expanded", String(open));
    frame.fitCap();
    // The steps open right above the chip: in sight (the answer and the
    // cards above them scroll up), once the stage has grown for them.
    if (open) frame.afterGrowth(() => frame.reveal(cloudBody));
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
  // To the card: its end in sight (the arrival's rule), or back up to it
  // for a reader below it (the cloud open under the card).
  pill.addEventListener("click", () => {
    if (!roomCard) return;
    if (roomCard.offsetTop < scroller.scrollTop) frame.easeStage(Math.max(0, roomCard.offsetTop - 8));
    else frame.reveal(extras);
  });
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
    if (e.detail) e.detail.until = new Promise((resolve) => frame.afterGrowth(resolve));
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

  // The cap and the frame (stage_frame.js): the stage's height, held while
  // it holds a turn, and its own scrolls.
  const frame = createStageFrame({
    stage, scroller, status, cloud, queuedSlot, holdEl, asking, extras, dockEl, centerEl, composerEl,
    observed: [status, promptSlot, live, extras, answer, tail, cloudBody, cloud, queuedSlot],
    isHolding: () => holding,
    isCollapsed: () => collapsed,
    isCloudOpen: () => cloudOpen,
    isRoomCap: () => roomCap,
  });

  // The in-use watch (stage_watch.js): an ended turn hands off once the
  // stage has not been in use for a while and nothing is pending.
  const watch = createInUseWatch({
    stage,
    watching: () => holding && !!endKind,
    onTick: ({ inUse, quietSinceMs, nowMs }) => handOffDue({ ended: true, pending: !settled || pendingCard(), inUse, quietSinceMs, nowMs }),
    onDue: () => handOff(),
  });

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

  function ensureQueuedSlot() {
    if (!queuedSlot.isConnected) stage.appendChild(queuedSlot);
  }

  function emptySlots() {
    for (const slot of [promptSlot, extras, answer, tail, cloudBody, queuedSlot, timingSlot]) slot.replaceChildren();
    slotsView.reset();
    rail?.reset();
    promptSlot.classList.remove("full");
    thinkingLine = null;
    flash = null;
    clearTimeout(flashTimer);
    if (roomCard) cardSight.unobserve(roomCard);
    roomCard = null;
    roomCap = false;
    measured = null;
    arrived = null;
    pill.hidden = true;
    setCloud(false);
    stage.classList.remove("plain", "ended", "waiting", "held-wait", "asking", "in-use", "question-room");
    stage.style.removeProperty("--live-held");
    live.style.minHeight = "";
  }

  // The turn leaves the stage's care (the hand-off's start, a reset, a new
  // turn): from here new rows, the next timing line and the history's
  // scroll are the history's (place, timingHost, holds). The slots keep
  // what they show until clearStage.
  function releaseTurn() {
    watch.stop();
    clearTimeout(settleTimer);
    holding = false;
    frame.resetHeld();
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
    frame.frameFree();
    if (revealed) {
      revealed = false;
      collapsed = readCollapsed();
      applyCollapsed();
    }
  }

  function release() {
    workingSet?.release();
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
    // The turn's set joins the page's turns (a plain one's too: the turns
    // keep their places); its footprint goes under the block.
    const footprint = workingSet ? workingSet.handOff(view.current().turn, promptWords()) : null;
    const pieces = handOffOrder({
      prompt: promptSlot.firstElementChild,
      block,
      footprint: block ? footprint : null,
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
      frame.resetHeld();
      frame.forgetContent();
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
      ensureQueuedSlot();
      queuedSlot.append(...waiting.filter((el) => !el.isConnected), ...historyEl.querySelectorAll(QUEUED_CHILDREN));
      view.turnStarted(data || {});
      show();
      refresh();
    },
    generationStarted(data, now = null) {
      releaseHeldWait();
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
      watch.start();
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
    // The asking slot pairs them on its next draw.
    questionRefs(refs) {
      view.questionRefs(refs);
      scheduleRefresh();
    },
    // The turn model and its live phase as the status row reads it (the
    // composer's delivery line).
    current: () => view.current(),
    phase: () => liveSlots(view.current().turn, { pending: pendingCard() || asksCard() }).phase,
    // Another session opens, or this one renders again: a turn still
    // sliding away is dropped (its history is about to be drawn anew),
    // never moved into whatever history shows now.
    reset() {
      folding = null;
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
        ensureQueuedSlot();
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
      // below, out of sight (once the stage has grown for it). A question
      // with the room reads from the reply's start instead (its pill leads
      // to the card); its pill shows from here on.
      if (waits) {
        frame.afterGrowth(() => {
          const ask = askCard();
          frame.reveal(slot, { fromStart: !!ask && ask === roomCard });
          arrived = ask;
          drawPill();
        });
      }
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
