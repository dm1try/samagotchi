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
// rules are pure in stage_model.js; this module wires the stage (refresh,
// the lifecycle, the event API) and each feature is a module of its own
// (web-frontend.md, The stage's modules): the nodes are stage_dom.js's, the
// live slots stage_slots.js's, the cap and the held height stage_frame.js's,
// the in-use watch that times the hand-off stage_watch.js's, the hand-off
// itself stage_handoff.js's, where a row or a card goes stage_place.js's,
// the cloud stage_cloud.js's, the docked card and the fold stage_asking.js's,
// its pager stage_pager.js's, the waiting cards as data stage_waiting.js's,
// the answer's reading stage_answer.js's, the quiet signal stage_stall.js's
// and its clocks stage_quiet_clock.js's, the perf probe stage_probe.js's. A new
// stage feature goes into its own stage_<feature>.js, wired here in a few
// lines; each module resets itself from emptySlots.
import { createTurnBlock } from "./turn_block.js";
import { chipLabelText, flashOf, handOffDue, headlineOf, isPlain, liveSlots, MARKS, foldedRowText, phaseLabel, QUEUED_CHILDREN, stepSlotText } from "./stage_model.js";
import { createStageSlots, node } from "./stage_slots.js";
import { createStageDom } from "./stage_dom.js";
import { createStageAnswer } from "./stage_answer.js";
import { createStagePager } from "./stage_pager.js";
import { createStageCloud } from "./stage_cloud.js";
import { createStageHandoff } from "./stage_handoff.js";

// How long the stage slides away at the hand-off (dock_reserve.js).
export { FOLD_MS } from "./stage_handoff.js";
import { createStageFrame, reducedMotion } from "./stage_frame.js";
import { createInUseWatch } from "./stage_watch.js";
import { createStageStall } from "./stage_stall.js";
import { createStageQuietClock } from "./stage_quiet_clock.js";
import { formatDuration } from "./timing.js";
import { createWorkingSetRail } from "./working_set_rail.js";
import { createOpenedTurn } from "./stage_opened.js";
import { createStageAsking } from "./stage_asking.js";
import { cardIn, createStageWaiting, waitingKey } from "./stage_waiting.js";
import { stampRows } from "./working_set_view.js";
import { createOwnerWait } from "./stage_owner_wait.js";
import { measured } from "./stage_probe.js";
import { createStagePlace } from "./stage_place.js";

// The turn-end read (markdown, answer_display) settles within this, or the
// hand-off stops waiting for it.
const SETTLE_CAP_MS = 8000;
const FLASH_MS = 4000;

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
// The quiet signal's inputs (stage_quiet_clock.js): +clock+() the page's time,
// +streamLive+() the session's stream is open, +timingNote+() what the turn
// waits on (live_timing.js note), +serverGen+() a joiner's generation.
// +canCancel+() whether this turn's Stop turn shows (a participant's own
// turn only); +ownerWait+() the kind a participant's view waits for the
// owner on, or null (stage_owner_wait.js). +createWaiting+: the registry's
// factory (stage_waiting.js; a test passes an older one's shape).
export function createStageView({
  historyEl, isNearBottom: historyNearBottom, sawText, sessionId, dockEl, centerEl, taskStop = null,
  renderMarkdown, linkRefs, workingSet = null, onCancel = null, onHandedOff = null,
  clock = () => Date.now(), streamLive = () => true, timingNote = () => "", serverGen = () => null,
  canCancel = () => true, ownerWait = () => null, createWaiting = createStageWaiting,
}) {
  // The stage's nodes (stage_dom.js), then their behaviour here and in the
  // stage's modules.
  const {
    stage, status, mark, phaseEl, pager, pagePrev, pageLabel, pageNext, stepEl, timingSlot, miniTool, cancel, fold,
    scroller, promptSlot, live, headline, ownerWaitLine, now, trail, extras, asksText, answer, tail, cloudBody, holdEl,
    cloud, chip, chipLabel, ticks, queuedSlot,
  } = createStageDom(dockEl);
  cancel.addEventListener("click", async () => {
    if (!onCancel || cancel.disabled) return;
    cancel.disabled = true;
    try {
      await onCancel();
    } finally {
      cancel.disabled = false;
    }
  });
  const drawOwnerWait = createOwnerWait({ stage, line: ownerWaitLine, phaseEl });
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
  // The quiet signal: its span in the now row, its head after the timing
  // line (stage_stall.js), its clocks (stage_quiet_clock.js).
  const quiet = createStageQuietClock({
    stall: createStageStall({ stage, nowEl: now, timingSlot }), clock, streamLive, timingNote, serverGen,
    held: () => (holding ? view.current().turn : null), ended: () => !!endKind, pending: () => pendingCard(),
  });
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
  let rafPending = false;
  // A turn the page knows runs (the session says running) with none in the
  // stage to show (a join without its current_turn): the status row alone,
  // so Stop turn stays in reach (runningWithoutTurn).
  let bare = false;
  // The raised cap (stage_frame.js) of an approval too tall for the stage
  // (raiseForApproval), kept until the next step (releaseHeldWait).
  let roomCap = false;
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

  // The answer read from its top, an answered card's line, the prompt's
  // first words (stage_answer.js).
  const { showAnswerTop, settleAnsweredCard, promptWords } = createStageAnswer({
    stage, scroller, answer, extras, tail, frame: () => frame, promptEl: () => promptEl,
  });

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
  const waiting = createWaiting({ sessionId });
  // The e2e's stage check reads it off the node (spec/e2e/support/fixtures.js).
  stage.chiWaiting = () => waiting.list();
  let dockedAtLastRefresh = [];
  // The asking form and the stage's fold (stage_asking.js).
  const ask = createStageAsking({
    stage, extras, tail, scroller, fold, view, opener, frame: () => frame, isOpened: () => opened, setOpened,
    isEnded: () => !!endKind, promptEl: () => promptEl, setCloud: (open) => cloudView.setCloud(open), scheduleRefresh, pendingCard, waiting,
  });
  const {
    askedText, settleCards, askingCard, cardOf, foldedText, markOwnToggles,
    isCollapsed, drawCollapsed, applyCollapsed, setCollapsed,
  } = ask;

  // The docked cards' pager (stage_pager.js).
  const pagerView = createStagePager({ pager, pagePrev, pageLabel, pageNext, extras, waiting, cardOf, askingCard, refresh, frame: () => frame });

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

  // A card that blocks the turn waits (stage_waiting.js: every way a card
  // stops waiting settles it at once, also a replay's answer and next step
  // in one task, before the refresh).
  function pendingCard() {
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

  // The text under a docked check-in card, patched only when it changes.
  function drawAsksText(text) {
    if (asksText.textContent !== text) asksText.textContent = text;
    asksText.hidden = !text;
  }
  // A card answered or redrawn in place (its buttons gone) changes the
  // status without a turn event: at once (a microtask), so the slots swap in
  // the card's own task, never a frame apart.
  new MutationObserver(() => refresh()).observe(extras, { childList: true, subtree: true });

  // Timed when the perf probe is on (stage_probe.js).
  function refresh() {
    measured("stage:refresh", drawRefresh);
  }

  function drawRefresh() {
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
    pagerView.drawDocked(asking);
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
    quiet.tick(clock(), blocked);
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
    cloudBody.hidden = !cloudView.isOpen() || cloud.hidden;
    // Running: the step it is on. Ended: the count, unless the chip says it.
    stepEl.textContent = stepSlotText({ step: slots.step, ended: !!endKind, chipHidden: cloud.hidden });
    promptSlot.hidden = !promptSlot.firstChild;
    extras.hidden = !extras.firstChild;
    answer.hidden = !answer.firstChild;
    tail.hidden = !tail.firstChild;
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

  // One line in the trail for FLASH_MS, ahead of the calls (a newer flash
  // takes its place).
  function flashTrail(what) {
    if (!what) return;
    flash = { ...what, until: Date.now() + FLASH_MS };
    scheduleRefresh();
    clearTimeout(flashTimer);
    flashTimer = setTimeout(scheduleRefresh, FLASH_MS + 50);
  }

  // ── collapse, cloud, peek ────────────────────────────────────────────────

  // The cloud and its toggles (stage_cloud.js).
  const cloudView = createStageCloud({
    stage, cloud, cloudBody, chip, headline, view, opener, frame: () => frame, isOpened: () => opened, isCollapsed, setCollapsed,
    reveal: () => ask.reveal(), isHolding: () => holding, isFolding: () => handoff.isFolding(), finishFold: () => handoff.finishFold(),
  });

  fold.addEventListener("click", (e) => {
    e.stopPropagation();
    setCollapsed(!isCollapsed());
  });
  status.addEventListener("click", (e) => {
    if (isCollapsed() && !e.target.closest("button, a")) setCollapsed(false);
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
    isCloudOpen: () => cloudView.isOpen(),
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
    onDue: () => handoff.handOff(),
  });

  // ── show, clear, hand off ────────────────────────────────────────────────

  function show() {
    handoff.cancelFold();
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
    quiet.reset();
    rail?.reset();
    promptSlot.classList.remove("full");
    thinkingLine = null;
    flash = null;
    clearTimeout(flashTimer);
    roomCap = false;
    markOwnToggles();
    opener.reset();
    waiting.reset();
    placer.reset();
    dockedAtLastRefresh = [];
    miniTool.classList.remove("ts-mini-question");
    cloudView.reset();
    stage.classList.remove("plain", "ended", "waiting", "held-wait", "in-use", "asking-form", "asks-live");
    pagerView.reset();
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
    handoff.cancelFold();
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

  // The hand-off and its fold (stage_handoff.js).
  const handoff = createStageHandoff({
    stage, promptSlot, extras, answer, timingSlot, tail, queuedSlot, historyEl, historyNearBottom, view, opener, waiting,
    workingSet, isHolding: () => holding, ended: () => endKind, isOpened: () => opened, promptEl: () => promptEl,
    blockPlace, promptWords, isCollapsed, releaseTurn, clearStage, onHandedOff,
  });

  // Where a row or a card goes while the stage holds a turn (stage_place.js).
  const placer = createStagePlace({
    historyEl, extras, tail, queuedSlot, ensureQueuedSlot, handoff, quiet, view, opener, waiting, ask, frame: () => frame, refresh,
    scheduleRefresh, holding: () => holding, opened: () => opened, endKind: () => endKind, promptEl: () => promptEl, historyNearBottom,
  });

  function dropBare() {
    if (!bare) return;
    bare = false;
    stage.classList.remove("bare");
    delete stage.dataset.phase;
  }

  // ── the view interface (app.js) ──────────────────────────────────────────

  return {
    turnStarted(data) {
      handoff.settle();
      dropBare();
      // A turn that never ended (released, not handed off) leaves its queued
      // lines waiting still: they stay.
      const waiting = [...queuedSlot.children].filter((el) => el !== data?.promptBubble);
      if (holding) {
        if (endKind) handoff.handOff({ immediate: true });
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
      quiet.alive();
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
      quiet.alive();
      releaseHeldWait();
      view.generationStarted(data, now);
    },
    chunk(data) {
      quiet.alive();
      return view.chunk(data);
    },
    generationRestarted(data) {
      quiet.alive();
      return view.generationRestarted(data);
    },
    generationCompleted() {
      quiet.alive();
      return view.generationCompleted();
    },
    toolStarted(data) {
      quiet.alive();
      return view.toolStarted(data);
    },
    toolCompleted(data) {
      quiet.alive();
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
      quiet.alive();
      const placed = view.notice(data);
      if (placed) flashTrail(flashOf("notice", data));
      return placed;
    },
    steer(data) {
      quiet.alive();
      const placed = view.steer(data);
      if (placed) flashTrail(flashOf("steer", data));
      return placed;
    },
    // A warn card (a plugin's warning) stays in sight: false puts it in the
    // extras (place), not in its step inside the closed cloud.
    card(el) {
      quiet.alive();
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
      quiet.alive();
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
      handoff.reset();
      release();
    },
    // The stage's extras while it holds a turn, its queued slot, an opened
    // turn's history end; false: the history takes it (stage_place.js).
    place: (el) => placer.place(el),
    // What a card about to be placed waits as (card_kinds.js; stage_place.js).
    expectWaiting: (key, info) => placer.expect(key, info),
    // Where the live timing line goes (the status row), null: the history.
    timingHost: () => {
      handoff.settle();
      return holding ? timingSlot : null;
    },
    // Before anything else goes into the history (app.js): a turn still
    // sliding away gets there first.
    settleFold: () => handoff.settle(),
    // A turn is in the stage (running, or ended and not handed off yet):
    // nothing the turn does touches the history's scroll.
    holds: () => holding,
    // The page's turn runs but the stage holds none (+on+); false: it ended.
    // A turn the stage holds draws its own row: nothing to do then.
    runningWithoutTurn(on) {
      if (holding || handoff.isFolding()) return;
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
      quiet.tick(nowMs);
      if (holding && asksCard() && liveSlots(view.current().turn).tool?.startedAt != null) scheduleRefresh();
    },
    callClockActive: () => holding && asksCard() && !!liveSlots(view.current().turn).tool,
    // An input of the hooks changed (a participant's ownerWait, canCancel).
    redraw: () => scheduleRefresh(),
    handOff: handoff.handOff,
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
    // A plugin card redrawn in place that still waits (cards_place.js
    // upsertCard; +info+: card_kinds.js cardWait): its entry patched, or, for
    // a card in the stage that waits again (its actions back), arrived anew;
    // the stage redrawn at once (a new title changes no child: the extras'
    // observer doesn't see it).
    // An older stage_waiting.js (a mixed cache) has no update: arrive again,
    // which keeps an entry's order.
    updateWaiting: (key, info) => {
      const was = waiting.get(key);
      if (!waiting.update?.(key, info)) {
        const card = cardIn(extras, key) || cardIn(tail, key);
        if (!info?.kind || (!was && !card)) return;
        waiting.arrive(key, { kind: info.kind, docked: was ? was.docked : ask.docks(card), approval: !!was?.approval, summary: info.summary });
      }
      refresh();
    },
    // The waiting cards as data (the tests' and the harness's read).
    waiting: { list: () => waiting.list(), front: () => waiting.front(), docked: () => waiting.docked(), folded: () => waiting.folded(), count: (o) => waiting.count(o) },
    root: stage,
    scrollEl: scroller,
  };
}
