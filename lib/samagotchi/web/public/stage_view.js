// The stage of a running turn (the page's view of it): the active turn pinned
// above the composer, its own card floating over the dock's (out of the
// dock's flow: its height never moves the composer). It shows only
// what happens now in fixed slots (a status row, the prompt, a two-line
// headline, the running tool, a one-line trail of the last calls), the
// cards and rows that arrive meanwhile in their own capped scroller, the
// answer, and a chip with one tick per tool call, the stage's footer (no
// content above it can push it away): the "cloud", the turn block
// (turn_block.js) reused as is, opens above it as the scroller's last slot,
// newest step first while the turn runs. When the turn has ended and the stage is not
// in use, everything moves into the history in the turn block's order (the
// hand-off), so a handed-off turn reads like its reload. Slots are patched in place, never rebuilt from HTML: a selection
// and annotate survive. When a card waits for the user (a question, an
// approval, a delegate's relayed card, a hook's question, check-in), the
// turn opens in the history (stage_opened.js): the prompt, the block and the
// rows so far go there (chi's line before its own question or approval as a
// lead-in bubble), and the stage docks the card alone (the asking form)
// until the answer. The step limit's card goes under its ended turn. The
// rules are pure in stage_model.js; the live slots are drawn by
// stage_slots.js, the cap and the held height are stage_frame.js's, the
// in-use watch that times the hand-off is stage_watch.js's, the docked card
// and the fold are stage_asking.js's, and the waiting cards as data are
// stage_waiting.js's.
import { createTurnBlock } from "./turn_block.js";
import { openAfterEnd } from "./block_open.js";
import { chipLabelText, flashOf, handOffDue, handOffOrder, headlineOf, isPlain, liveSlots, MARKS, foldedRowText, phaseLabel, placeFor, placeKind, QUEUED_CHILDREN, stepSlotText } from "./stage_model.js";
import { createStageSlots, node } from "./stage_slots.js";
import { createStageFrame, reducedMotion } from "./stage_frame.js";
import { createInUseWatch } from "./stage_watch.js";
import { createStageStall, GRACE_MS, stallState } from "./stage_stall.js";
import { formatDuration } from "./timing.js";
import { easeScrollTo } from "./scroll.js";
import { createWorkingSetRail } from "./working_set_rail.js";
import { moveToHistoryEnd } from "./history_end.js";
import { turnElements } from "./turn_range.js";
import { createOpenedTurn } from "./stage_opened.js";
import { askingRefs } from "./turn_model.js";
import { ASKS, PENDING } from "./stage_cards.js";
import { createStageAsking } from "./stage_asking.js";
import { cardIn, createStageWaiting, isApprovalCard, isBlocking, waitingKey, waitingKind } from "./stage_waiting.js";
import { stampRows } from "./working_set_view.js";
import { createOwnerWait } from "./stage_owner_wait.js";

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
// An answered card's one line.
const ANSWERED_LINE = 40;
// That line brought back sits this far under the scroller's edge.
const ANSWERED_GAP = 8;
// What opens a turn in the history (reload_check.js's OPENING).
const OPENING = "[data-turn-id], [data-opening-id]";

// +historyNearBottom+: the history's own follow check (the hand-off scrolls
// the history only for a reader at its end). +dockEl+ and +centerEl+ size
// the stage's cap.
// +taskStop+: the page's stopper (task_stop.js), for the stop-task button
// on a running task_wait. +renderMarkdown+ and +linkRefs+: a lead-in
// bubble's markdown read and ref pass (stage_opened.js). +workingSet+: the
// page's working set (working_set_view.js, web.working_set; null: off): its
// rail in the live slots, its footprint at the hand-off. +onCancel+: the
// status row's Stop turn (a promise of the cancel request; the button is
// disabled until it settles); null: no Stop turn. +onHandedOff+({pieces,
// immediate}): a turn's pieces reached the history (reload_check.js).
// The quiet signal's inputs (stage_stall.js): +clock+() the page's time,
// +streamLive+() the session's stream is open, +timingNote+() what the turn
// waits on (live_timing.js note), +serverGen+() a joiner's generation.
// +canCancel+() whether this turn's Stop turn shows (a participant's own
// turn only); +ownerWait+() the kind a participant's view waits for the
// owner on, or null (stage_owner_wait.js).
export function createStageView({
  historyEl, isNearBottom: historyNearBottom, sawText, sessionId, dockEl, centerEl, taskStop = null,
  renderMarkdown, linkRefs, workingSet = null, onCancel = null, onHandedOff = null,
  clock = () => Date.now(), streamLive = () => true, timingNote = () => "", serverGen = () => null,
  canCancel = () => true, ownerWait = () => null,
}) {
  // The dock becomes a clear column: the stage's card, then the composer's
  // (its rows moved into .dock-card, which wears the glass and the focus ring).
  document.body.classList.add("stage-view");
  const card = node("div", "dock-card composer-card");
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
  // Two cards docked: one at a time, "‹ 1 of 2 ›" (stage_waiting.js shown).
  const pager = node("span", "ts-pager", status);
  pager.hidden = true;
  const pagePrev = node("button", "ts-page", pager);
  pagePrev.type = "button";
  pagePrev.textContent = "‹";
  pagePrev.setAttribute("aria-label", "The card before");
  const pageLabel = node("span", "ts-page-label", pager);
  const pageNext = node("button", "ts-page", pager);
  pageNext.type = "button";
  pageNext.textContent = "›";
  pageNext.setAttribute("aria-label", "The next card");
  const stepEl = node("span", "ts-step", status);
  const timingSlot = node("span", "ts-timing", status);
  const miniTool = node("span", "ts-mini", status);
  const defer = node("span", "ts-defer", status);
  defer.textContent = "moves up when you leave";
  // Stop turn, at the row's right edge beside the fold: while the turn
  // hasn't ended (refresh), in a collapsed stage too (the row stays).
  const cancel = node("button", "ts-cancel", status);
  cancel.type = "button";
  cancel.title = "Cancel the running turn, whoever sent it";
  cancel.textContent = "Stop turn";
  cancel.hidden = true;
  cancel.addEventListener("click", async () => {
    if (!onCancel || cancel.disabled) return;
    cancel.disabled = true;
    try {
      await onCancel();
    } finally {
      cancel.disabled = false;
    }
  });
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
  // A participant's turn waiting for the owner: one line under the headline, no card.
  const drawOwnerWait = createOwnerWait({ stage, line: node("div", "ts-owner-wait", live), phaseEl });
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
  // While check-in's card is docked: the live step's text, streamed under
  // the card (the steps are in the history then). The answer's own slot
  // takes it over at the turn's end (placeAnswer, in one task).
  const asksText = node("div", "ts-asks-text", scroller);
  asksText.hidden = true;
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
  // The quiet signal: its span in the now row, its head after the timing line.
  const stall = createStageStall({ stage, nowEl: now, timingSlot });
  const slotsView = createStageSlots({
    headline, now, trail, ticks, taskStop,
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
  let cloudOpen = false;
  let rafPending = false;
  // A turn the page knows runs (the session says running) with none in the
  // stage to show (a join without its current_turn): the status row alone,
  // so Stop turn stays in reach (runningWithoutTurn).
  let bare = false;
  let foldTimer = null;
  // The raised cap (stage_frame.js) of an approval too tall for the stage
  // (raiseForApproval), kept until the next step (releaseHeldWait).
  let roomCap = false;
  // The quiet signal's clocks: the turn's last event, since when the stream
  // isn't live (null: it is), the grace after the page shows again.
  let lastEventAt = 0;
  let downSince = null;
  let graceUntil = 0;
  // Where the turn's prompt and block are: the stage (its prompt slot, the
  // cloud or a plain turn's answer slot), or the history once the turn is
  // opened there (+opened+). Read through blockPlace and promptEl, never
  // the DOM parent alone.
  let opened = false;
  let promptEl = null;

  // The stage says where its turn's block is (refs.js turnBlockOf: a row in
  // the stage belongs to the block in the history then).
  function setOpened(value) {
    opened = value;
    if (value) stage.dataset.block = "history";
    else delete stage.dataset.block;
  }

  // The turn opened in the history while the model's own question waits
  // (stage_opened.js): its reasons, and the moves there.
  const opener = createOpenedTurn({
    historyEl, atHistoryEnd: historyNearBottom, renderMarkdown, linkRefs, reduce: reducedMotion,
    afterSettle: (fn) => frame.afterGrowth(fn),
  });

  const view = createTurnBlock({
    historyEl,
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
      drawAsksText("");
      answer.append(...pieces);
      showAnswerTop();
    },
    taskStop,
    onChange: () => scheduleRefresh(),
    onThinkingLine: (text) => {
      const { turn } = view.current();
      thinkingLine = { step: turn ? turn.gens.length : 0, text };
      scheduleRefresh();
    },
  });

  // The cards that wait in the stage, as data (stage_waiting.js): the
  // docked card, its fold, what blocks, the approval's cap read them. The
  // fold of the asking card is this tab's own, kept per session.
  const waiting = createStageWaiting({ sessionId });
  let dockedAtLastRefresh = [];
  // The asking form and the stage's fold (stage_asking.js).
  const ask = createStageAsking({
    stage, extras, tail, scroller, fold, view, opener, frame: () => frame, isOpened: () => opened, setOpened,
    isEnded: () => !!endKind, promptEl: () => promptEl, setCloud, scheduleRefresh, pendingCard, waiting,
  });
  const {
    askingGen, asksOf, askedFor, askedText, docks, leadInText, openTurn, settleCards, askingCard, cardOf, foldedText, markOwnToggles,
    isCollapsed, drawCollapsed, applyCollapsed, setCollapsed,
  } = ask;

  // ── slots ────────────────────────────────────────────────────────────────

  // "history" (an opened turn's), "cloud", "answer" (a plain turn's in
  // the stage), null: no block.
  function blockPlace(blockEl = view.current().blockEl) {
    if (!blockEl) return null;
    if (opened) return "history";
    return blockEl.parentNode === cloudBody ? "cloud" : "answer";
  }

  function scheduleRefresh() {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(refresh);
  }

  // A card that blocks the turn waits (stage_waiting.js, checked against
  // the slots first: a replay answers a card and starts the next step in one
  // task, before the refresh).
  function pendingCard() {
    ask.reconcileWaiting();
    return waiting.count() > 0;
  }

  // A blocking approval too tall for the stage's view: a raised cap, the
  // stage takes what the page has. The card still opens at its question and
  // command (stage_frame.js revealTop). The cap is a ceiling: a card that
  // fits never gets here.
  function raiseForApproval(blocked) {
    if (!blocked || roomCap) return;
    const front = waiting.get(waiting.front());
    const card = front?.approval ? cardOf(front.key) : null;
    if (!card || frame.fitsCap(card)) return;
    roomCap = true;
    frame.fitCap();
  }

  // An asking card (check-in) waits while the turn runs.
  function asksCard() {
    return !endKind && waiting.count({ asks: true }) > waiting.count();
  }

  // One docked card at a time: the others wait behind it (.ts-behind) and
  // the pager says where the shown one is.
  function drawDocked(shownCard) {
    const keys = waiting.docked();
    for (const key of keys) cardOf(key)?.classList.toggle("ts-behind", !!shownCard && cardOf(key) !== shownCard);
    for (const el of extras.querySelectorAll(":scope > .ts-behind")) if (!keys.includes(waitingKey(el))) el.classList.remove("ts-behind");
    // Focus in a card that went behind (a new card came in front of it):
    // to the card that shows now.
    const focused = document.activeElement;
    if (shownCard && focused && [...extras.querySelectorAll(":scope > .ts-behind")].some((el) => el.contains(focused))) focusIn(shownCard);
    const at = shownCard ? keys.indexOf(waitingKey(shownCard)) : -1;
    pager.hidden = keys.length < 2 || at < 0;
    if (pager.hidden) return;
    const label = `${at + 1} of ${keys.length}`;
    if (pageLabel.textContent !== label) pageLabel.textContent = label;
    pagePrev.disabled = at === 0;
    pageNext.disabled = at === keys.length - 1;
    // A pager button the page just disabled keeps no focus: the other one has it.
    if (document.activeElement === pagePrev && pagePrev.disabled) pageNext.focus();
    else if (document.activeElement === pageNext && pageNext.disabled) pagePrev.focus();
  }

  // +card+'s first control takes the focus (its summary is out of the tab
  // order while it waits), else the card.
  function focusIn(card) {
    const control = card.querySelector('input:not([type="hidden"]), textarea, select, button:not([disabled]), a[href]');
    if (control) control.focus();
    else {
      if (!card.hasAttribute("tabindex")) card.tabIndex = -1;
      card.focus();
    }
  }
  for (const [button, by] of [[pagePrev, -1], [pageNext, 1]]) {
    button.addEventListener("click", (e) => {
      e.stopPropagation();
      waiting.page(by);
      refresh();
      const shown = askingCard();
      if (shown) frame.afterGrowth(() => frame.reveal(shown.parentElement));
    });
  }

  // The text under a docked check-in card, patched only when it changes.
  function drawAsksText(text) {
    if (asksText.textContent !== text) asksText.textContent = text;
    asksText.hidden = !text;
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
    // The stage hosts the block (an opened turn's is in the history).
    if (blockEl && !endKind && !opened) {
      const host = plain ? answer : cloudBody;
      if (blockEl.parentNode !== host) host.appendChild(blockEl);
    }
    const place = blockPlace(blockEl);
    // The turn block closes at the end; the cloud shows its steps.
    if (place === "cloud") blockEl.open = true;
    const narration = gen?.text ? headlineOf(gen.text, gen.textDone || gen.closed) : "";
    const thinking = thinkingLine && thinkingLine.step === turn.gens.length ? thinkingLine.text : "";
    // A question blocks the turn: its card takes the live slots' room. An
    // asking card's turn goes on: the status waits, the slots stay.
    ask.reconcileWaiting();
    settleCards();
    markOwnToggles();
    const blocked = pendingCard();
    // The asking form: a docked card waits (the card alone in the stage;
    // its turn is in the history, a reply before it the lead-in bubble).
    const asking = askingCard();
    const askingForm = !!asking;
    stage.classList.toggle("asking-form", askingForm);
    // Its fold (stage_asking.js trackFold): that card's only.
    ask.trackFold();
    drawDocked(asking);
    const collapsed = isCollapsed();
    drawCollapsed();
    const slots = liveSlots(turn, { narration, thinking, pending: blocked || asksCard(), ended: endKind, emptyAnswer });

    // The live slots keep their height while the turn waits and until its
    // next step, unless answering leaves another docked card to fit. The
    // waiting height is measured before the swap.
    const wasWaiting = stage.classList.contains("waiting");
    const docked = waiting.docked();
    const answeredWithCardLeft = dockedAtLastRefresh.some((key) => !docked.includes(key)) && docked.length > 0;
    dockedAtLastRefresh = docked;
    if (blocked && !wasWaiting) {
      stage.classList.add("held-wait");
    }
    if (!blocked && wasWaiting) stage.style.setProperty("--live-held", `${live.offsetHeight}px`);
    stage.classList.toggle("plain", plain);
    stage.classList.toggle("ended", !!endKind);
    cancel.hidden = !onCancel || !canCancel() || !!endKind;
    stage.classList.toggle("waiting", blocked);
    if (!blocked && wasWaiting) settleAnsweredCard();
    if (answeredWithCardLeft && !blocked) releaseHeldWait();
    stage.dataset.phase = slots.phase;
    mark.textContent = MARKS[slots.phase] || "";
    // check-in docked, nothing blocking: the row says what chi does now (the
    // running call, "writing" while text streams) and the text streams
    // under the card.
    const asksFront = !!asking && !blocked && !endKind && waiting.get(waiting.front())?.kind === "asks";
    const streaming = asksFront ? liveSlots(turn).phase : "";
    phaseEl.textContent = phaseLabel({ phase: slots.phase, asksFront, streaming });
    drawOwnerWait(endKind ? null : ownerWait());
    stage.classList.toggle("asks-live", asksFront);
    drawAsksText(asksFront && gen?.text && !gen.answer ? String(gen.text).trim() : "");

    slotsView.drawHeadline(slots.headline);
    raiseForApproval(blocked);
    slotsView.drawNow(slots.tool, slots.quiet);
    drawStall(clock(), blocked);
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
    // Folded, the row says what the docked card asks (live and after a
    // reload alike: from the card), else the running call.
    const mini = foldedRowText({ collapsed, question: foldedText(asking), tool: slots.tool, running: asksFront, now: clock() });
    if (mini.clock) {
      miniTool.replaceChildren();
      node("span", "ts-mini-label", miniTool).textContent = mini.text;
      node("span", "ts-mini-clock", miniTool).textContent = ` · ${mini.clock}`;
      miniTool.classList.add("ts-mini-timed");
    } else {
      miniTool.classList.remove("ts-mini-timed");
      miniTool.textContent = mini.text;
    }
    miniTool.title = mini.title;
    miniTool.classList.toggle("ts-mini-question", mini.question);

    // An ended turn's live slots go, unless something under them would move
    // (a card or a row in the extras): then they stay as they were last.
    live.hidden = plain || (!!endKind && !extras.firstChild);
    // The chip: a block in the cloud. An opened turn's steps line in the
    // history says the count: none here.
    cloud.hidden = place !== "cloud";
    cloudBody.hidden = !cloudOpen || cloud.hidden;
    // Running: the step it is on. Ended: the count, unless the chip says it.
    stepEl.textContent = stepSlotText({ step: slots.step, ended: !!endKind, chipHidden: cloud.hidden });
    promptSlot.hidden = !promptSlot.firstChild;
    extras.hidden = !extras.firstChild;
    answer.hidden = !answer.firstChild;
    tail.hidden = !tail.firstChild;
  }

  // A card stopped waiting and its slot has its cap and own scroll again: the
  // slot's end shows (the answered card's line). The stage's scroll stays, so
  // nothing moves at the tap (the frame holds, and the blank goes at the next
  // step), unless the reader had scrolled down the tall card past its line:
  // then the line comes back, to the view's top and no further.
  function settleAnsweredCard() {
    const slot = tail.firstChild ? tail : extras;
    if (!slot.firstChild) return;
    slot.scrollTop = slot.scrollHeight;
    const end = slot.offsetTop + slot.offsetHeight;
    // Strictly below: offsetTop/offsetHeight are rounded, so a scroll exactly
    // at the line's edge can leave it a fraction of a pixel above the view.
    if (scroller.scrollTop < end - ANSWERED_LINE) return;
    scroller.scrollTop = Math.max(0, Math.min(slot.lastElementChild.offsetTop, end - ANSWERED_LINE) - ANSWERED_GAP);
  }

  // The prompt's first words (the working set's session tags say whose
  // turn a step was).
  function promptWords() {
    const text = (promptEl?.querySelector(".user-message")?.textContent || "").replace(/\s+/g, " ").trim();
    return text.length > 60 ? `${text.slice(0, 59)}\u2026` : text;
  }

  // The next step after a blocking card's answer, or an answer that leaves
  // another docked card in front: the frame shrinks (stage_frame.js
  // forgetContent; grow-only otherwise). What the wait held goes together:
  // the live slots' waiting height, a raised cap, the tallest content seen.
  // +held-wait+ says it is due, so later steps change nothing.
  // A card still pending is read from the slots, not the waiting class: a
  // replay (a reload, a resync) runs its answer and the next step in one
  // task, before the refresh that drops the class.
  function releaseHeldWait() {
    if (!stage.classList.contains("held-wait") || pendingCard()) return;
    stage.classList.remove("held-wait");
    stage.style.removeProperty("--live-held");
    roomCap = false;
    frame.fitCap();
    frame.forgetContent();
  }

  // ── the quiet signal (stage_stall.js) ─────────────────────────────────────

  // At +nowMs+ (the tick's, a refresh's): what the turn's silence says.
  function drawStall(nowMs, blocked = pendingCard()) {
    const { turn } = view.current();
    if (!holding || !turn) return;
    if (streamLive()) downSince = null;
    else downSince ??= nowMs;
    stall.draw(stallState({
      turn, lastEventAt, nowMs, blocked, note: timingNote() || "", ended: !!endKind, graceUntil, serverGen: serverGen(),
      streamDownMs: downSince === null ? null : nowMs - downSince,
    }));
  }

  // A turn event arrived (a replay's too): the silence starts over, and a
  // stall shown clears at once.
  function alive() {
    lastEventAt = clock();
    if (stall.level()) drawStall(lastEventAt);
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) graceUntil = clock() + GRACE_MS;
  });

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
    // An opened turn's step is in the history: shown there.
    if (opened) {
      if (!step.el.open) step.summary.click();
      opener.reveal(step.el);
      return;
    }
    if (isCollapsed()) setCollapsed(false);
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
    setCollapsed(!isCollapsed());
  });
  status.addEventListener("click", (e) => {
    if (isCollapsed() && !e.target.closest("button, a")) setCollapsed(false);
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
    if (isCollapsed()) ask.reveal();
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
    stage, scroller, status, cloud, queuedSlot, holdEl, extras, dockEl, centerEl,
    observed: [status, promptSlot, live, extras, asksText, answer, tail, cloudBody, cloud, queuedSlot],
    isHolding: () => holding,
    isCollapsed,
    isCloudOpen: () => cloudOpen,
    isRoomCap: () => roomCap,
    waitingCard: () => (stage.classList.contains("waiting") ? cardOf(waiting.front()) : null),
  });

  // The in-use watch (stage_watch.js): an ended turn hands off once the
  // stage has not been in use for a while and nothing is pending.
  const watch = createInUseWatch({
    stage,
    // An opened turn's reasons in the history: read there, they hold it too.
    alsoWatched: () => opener.watched(),
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
    drawAsksText("");
    setOpened(false);
    promptEl = null;
    // The turn left the stage: the status row and the chip say nothing until
    // the next one. Kept as they were, a hidden stage still reads "thinking ·
    // step 1" — the stale stage of a turn the page stopped following.
    mark.textContent = "";
    phaseEl.textContent = "";
    stepEl.textContent = "";
    miniTool.textContent = "";
    cancel.hidden = true;
    chipLabel.textContent = "";
    slotsView.reset();
    stall.reset();
    downSince = null;
    rail?.reset();
    promptSlot.classList.remove("full");
    thinkingLine = null;
    flash = null;
    clearTimeout(flashTimer);
    roomCap = false;
    markOwnToggles();
    opener.reset();
    waiting.reset();
    dockedAtLastRefresh = [];
    miniTool.classList.remove("ts-mini-question");
    setCloud(false);
    stage.classList.remove("plain", "ended", "waiting", "held-wait", "in-use", "asking-form", "asks-live");
    pager.hidden = true;
    stage.style.removeProperty("--live-held");
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
    dropBare();
    cancelFold();
    emptySlots();
    stage.hidden = true;
    frame.frameFree();
    ask.unreveal();
  }

  function release() {
    workingSet?.release();
    releaseTurn();
    clearStage();
  }

  // The hand-off: everything the stage holds goes into the history's end in
  // the turn block's order (prompt, block (chronological; its outline open,
  // else collapsed), extras, answer, timing line, then the end line and
  // what came after the end). The turn is released at once; the stage
  // slides away under the composer still drawn (a transform: nothing on the
  // page moves; app.js eases the history's bottom reserve meanwhile), then
  // the pieces arrive in the history and it follows a reader who was at its
  // end. Not with +immediate+ (another turn takes the stage at once), a
  // reduced motion, a hidden page or a collapsed stage: all at once.
  let folding = null; // { pieces, block, endKind, wasAtEnd, animate } while it slides
  function handOff({ immediate = false } = {}) {
    if (folding && immediate) finishFold();
    if (!holding || !endKind) return;
    const { blockEl } = view.current();
    view.chronological();
    const place = blockPlace(blockEl);
    // A finished turn's block draws as a reload draws it.
    if (blockEl) delete blockEl.dataset.openedTurn;
    // The block moves with the pieces from the cloud; an opened turn's is
    // in the history already.
    const block = place === "cloud" ? blockEl : null;
    // The turn's set joins the page's turns (a plain one's too: the turns
    // keep their places); its footprint takes the block's summary line,
    // wherever the block is.
    const footprint = workingSet ? workingSet.handOff(view.current().turn, promptWords()) : null;
    if ((place === "cloud" || place === "history") && footprint) blockEl.querySelector(":scope > summary > .tw-sum")?.prepend(footprint);
    const pieces = handOffOrder({
      // The prompt still in its slot (an opened turn's is in the history).
      prompt: !opened && promptEl?.parentNode === promptSlot ? promptEl : null,
      block,
      extras: [...extras.children].map((el) => { el.classList.remove("ts-behind"); return el; }),
      answer: [...answer.children],
      timing: timingSlot.firstElementChild,
      kept: [...tail.children],
      queued: [...queuedSlot.children],
    });
    const animate = !immediate && !reducedMotion() && !document.hidden && !isCollapsed();
    folding = { pieces, block: blockEl, endKind, wasAtEnd: historyNearBottom(), animate, immediate, opened, prompt: promptEl };
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
    // The stage held it open; here it takes its place in the history:
    // closed, unless the turn was cut short with an outline (block_open.js).
    if (fold.block) fold.block.open = openAfterEnd(fold.endKind, fold.block.classList.contains("outline"));
    // A piece removed while it slid (the old continue card the step-limit
    // question replaces) stays gone.
    fold.pieces = fold.pieces.filter((el) => el.isConnected);
    moveToHistoryEnd(historyEl, fold.pieces, { animate: fold.animate });
    // An opened turn's reasons go in the pieces' task (after them: the
    // history is as tall as it gets, room to keep the reader's rows in
    // place): each answered card's clamp says it now, as the turn reloads.
    opener.end();
    // The asking card's fold is this turn's: with the turn handed off, there
    // is nothing for a reload to bring back.
    waiting.clearFold();
    clearStage();
    if (fold.wasAtEnd) easeScrollTo(historyEl, () => historyEl.scrollHeight - historyEl.clientHeight, { reduce: !fold.animate || reducedMotion() });
    // The turn's pieces are in the history now (the opt-in reload check,
    // reload_check.js), the whole turn from its opening: an opened turn's
    // earlier pieces went before, and a wake's or a reminder's turn has no
    // prompt (its note opens it); +immediate+: another turn took the stage.
    onHandedOff?.({ pieces: wholeTurn(fold), immediate: fold.immediate });
  }

  // A handed-off turn from its opening: its prompt, else the wake's note
  // (data-opening-id) right before its first piece; the pieces as they are
  // when the first is its opening, or nothing opens it.
  function wholeTurn(fold) {
    const first = fold.pieces[0];
    if (first?.matches?.(OPENING) && !fold.opened) return fold.pieces;
    let opening = fold.prompt?.isConnected && fold.prompt.parentElement === historyEl ? fold.prompt : null;
    for (let el = (fold.block || first)?.previousElementSibling; !opening && el; el = el.previousElementSibling) {
      if (el.matches("[data-turn-id]")) break;
      if (el.matches("[data-opening-id]")) opening = el;
    }
    if (!opening) return fold.pieces;
    // Its rows, notes too (a note that reached the history mid-turn is the turn's).
    return [opening, ...turnElements(opening, { container: historyEl, boundary: null })];
  }

  function dropBare() {
    if (!bare) return;
    bare = false;
    stage.classList.remove("bare");
    delete stage.dataset.phase;
  }

  // ── the view interface (app.js) ──────────────────────────────────────────

  return {
    turnStarted(data) {
      if (folding) finishFold();
      dropBare();
      // A turn that never ended (released, not handed off) leaves its queued
      // lines waiting still: they stay.
      const waiting = [...queuedSlot.children].filter((el) => el !== data?.promptBubble);
      if (holding) {
        if (endKind) handOff({ immediate: true });
        else {
          // A turn that never ended (its end lost): its reasons, still
          // "asking you", go; what it moved into the history stays.
          opener.drop();
          release();
        }
      }
      holding = true;
      frame.resetHeld();
      frame.forgetContent();
      endKind = null;
      emptyAnswer = false;
      settled = true;
      startedAt = Date.parse(data?.started_at) || Date.now();
      emptySlots();
      lastEventAt = clock();
      // The turn's prompt bubble (app.js found or drew it) sits in the prompt
      // line until the hand-off takes it back first.
      promptEl = data?.promptBubble || null;
      if (promptEl) promptSlot.appendChild(promptEl);
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
      alive();
      releaseHeldWait();
      view.generationStarted(data, now);
    },
    chunk(data) {
      alive();
      return view.chunk(data);
    },
    generationRestarted(data) {
      alive();
      return view.generationRestarted(data);
    },
    generationCompleted() {
      alive();
      return view.generationCompleted();
    },
    toolStarted(data) {
      alive();
      return view.toolStarted(data);
    },
    toolCompleted(data) {
      alive();
      return view.toolCompleted(data);
    },
    turnEnded(args) {
      const kept = view.turnEnded(args) || [];
      if (!holding) return kept;
      // The warn cards the extras kept in sight leave the turn with the
      // block's (card.js leavesBlock): after the end line, as a reload has them.
      const warn = [...extras.querySelectorAll(":scope > .plugin-card.warn")];
      warn.forEach((el) => {
        el.remove();
        waiting.settle(waitingKey(el), { only: "warn" });
      });
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
      alive();
      const placed = view.notice(data);
      if (placed) flashTrail(flashOf("notice", data));
      return placed;
    },
    steer(data) {
      alive();
      const placed = view.steer(data);
      if (placed) flashTrail(flashOf("steer", data));
      return placed;
    },
    // A warn card (a plugin's warning) stays in sight: false puts it in the
    // extras (place), not in its step inside the closed cloud.
    card(el) {
      alive();
      return !el.classList.contains("warn") && view.card(el);
    },
    flush: () => view.flush(),
    answerReady() {
      settled = true;
      clearTimeout(settleTimer);
    },
    containsLive: (el) => view.containsLive(el),
    // The reply that asked (question_cards.js keeps it for the answered
    // card's two lines), a replayed question's too.
    askingText: (pq) => askedText(pq),
    // A lead-in bubble drawn after this pairs them (askingRefs).
    questionRefs(refs) {
      alive();
      view.questionRefs(refs);
      scheduleRefresh();
    },
    // The turn model and its live phase as the status row reads it (the
    // composer's delivery line).
    current: () => view.current(),
    // Only a card that blocks says "goes in once the card above is
    // answered": check-in leaves the composer free.
    phase: () => liveSlots(view.current().turn, { pending: pendingCard() }).phase,
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
      const waits = !!(el.matches?.(PENDING) || el.querySelector?.(ASKS));
      const kind = placeKind(el);
      const where = placeFor({ live: holding, handingOff: false, kind, opened: opened && !endKind });
      // A late recap (idle-only, it describes the chat before this turn)
      // goes above an opened turn, not inside it.
      const above = kind === "recap" && opened ? [promptEl, view.current().blockEl].find((x) => x?.parentElement === historyEl) : null;
      if (above) {
        historyEl.insertBefore(el, above);
        return true;
      }
      if (where === "history") return false;
      alive();
      if (where === "queued") {
        ensureQueuedSlot();
        queuedSlot.appendChild(el);
        scheduleRefresh();
        return true;
      }
      // An opened turn's row: the history's end, in arrival order; a card
      // that stopped waiting before it (a replay answers it and steers in
      // one task, before the refresh) goes there first.
      if (where === "opened") {
        ask.reconcileWaiting();
        settleCards();
        opener.add(el);
        scheduleRefresh();
        return true;
      }
      // A card that waits for the user docks: the turn opens in the
      // history, a lead-in lands there in this task, the card stays here.
      const docked = docks(el);
      const key = waitingKey(el);
      // A card drawn again with its key (the same question) keeps its lead-in.
      const kept = docked && opener.has(key);
      const reason = docked && !kept ? leadInText(el) : "";
      // Read before the turn's pieces make the history taller: with no
      // lead-in to read, a reader at the end follows the turn's move.
      const atEnd = docked ? historyNearBottom() : false;
      if (docked) openTurn({ follow: atEnd && !reason });
      const slot = endKind ? tail : extras;
      const stick = slot.scrollHeight - slot.scrollTop - slot.clientHeight < 24;
      // The stage's order (stage_waiting.js): a card that blocks goes before
      // the asking ones, as a reload places them.
      const behind = isBlocking(waitingKind(el)) ? [...slot.children].find((x) => waitingKind(x) === "asks") : null;
      slot.insertBefore(el, behind || null);
      slot.hidden = false;
      // The card is the stage's to keep (stage_waiting.js): docked when it
      // waits for the user (its lead-in is the opener's, by the same key).
      const waitKind = waitingKind(el);
      if (waitKind) waiting.arrive(key, { kind: waitKind, docked, approval: isApprovalCard(el) });
      if (stick || waits) slot.scrollTop = slot.scrollHeight;
      if (kept) opener.relink(key, el);
      if (reason) {
        const { turn } = view.current();
        opener.ask({
          card: el, key, text: reason, refs: askingRefs(turn) || askingGen(asksOf(el))?.refs || null, step: turn?.gens.length || 0,
          turnId: promptEl?.dataset.turnId || null, questionId: el.dataset.qid ?? null, follow: atEnd,
        });
      }
      // The step limit: its card goes under its ended turn in the
      // conversation at once, as a reload draws it (the hand-off: its fold,
      // the history's follow and the reload check as for any finished turn;
      // the in-use watch and the end read don't hold it).
      if (endKind && waitKind === "continue") {
        handOff();
        return true;
      }
      // A waiting card and the asking form (refresh) land in one task.
      if (waits) refresh();
      else scheduleRefresh();
      // The asking form: the stage shrinks to the card; an answer can also
      // shrink it to a remaining card, or release it at the next step.
      if (docked) frame.forgetContent();
      if (waits && el.matches?.(".bubble.question")) askedFor(el);
      // A card that waits for the user is brought into the stage's view: in
      // a short window the prompt and headline fill it and the card sat
      // below, out of sight (once the stage has grown for it).
      if (waits) frame.afterGrowth(() => frame.reveal(slot));
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
    // The page's turn runs but the stage holds none (+on+); false: it ended.
    // A turn the stage holds draws its own row: nothing to do then.
    runningWithoutTurn(on) {
      if (holding || folding) return;
      if (!on) {
        if (bare) clearStage();
        return;
      }
      emptySlots();
      bare = true;
      stage.classList.add("bare");
      stage.dataset.phase = "running";
      phaseEl.textContent = "running";
      cancel.hidden = !onCancel || !canCancel();
      show();
    },
    // The page's clock ticks (app.js, the live timing's 200 ms / 1 s): the
    // quiet signal and the running call's clock.
    tick(nowMs = clock()) {
      drawStall(nowMs);
      if (holding && asksCard() && liveSlots(view.current().turn).tool?.startedAt != null) scheduleRefresh();
    },
    callClockActive: () => holding && asksCard() && !!liveSlots(view.current().turn).tool,
    // An input of the hooks changed (a participant's ownerWait, canCancel).
    redraw: () => scheduleRefresh(),
    handOff,
    // A card stopped waiting (stage_waiting.js keys; +only+: when it is that
    // kind): question_cards.js's resolve path, cards_place.js upsertCard.
    // The stage's redraw comes from the card's own change.
    settleWaiting: (key, opts) => {
      const settled = waiting.settle(key, opts);
      if (!settled || !opener.has(key)) return settled;
      const card = cardIn(extras, key) || cardIn(tail, key);
      card?.classList.remove("ts-behind");
      opener.settle(key, card);
      return true;
    },
    // The waiting cards as data (the tests' and the harness's read).
    waiting: { list: () => waiting.list(), front: () => waiting.front(), docked: () => waiting.docked(), folded: () => waiting.folded(), count: (o) => waiting.count(o) },
    root: stage,
    scrollEl: scroller,
  };
}
