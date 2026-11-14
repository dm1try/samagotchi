// The stage's hand-off (stage_view.js): an ended turn's pieces go into the
// history's end in the turn block's order, the stage sliding away under the
// composer meanwhile (the fold). Its own module: new exports go in new
// modules (web-frontend.md). Its state (the turn sliding away) outlives
// emptySlots on purpose: the fold runs after the turn's release, and
// finishFold clears the stage; reset() (the view's reset) drops it.
import { openAfterEnd } from "./block_open.js";
import { handOffOrder } from "./stage_model.js";
import { reducedMotion } from "./stage_frame.js";
import { easeScrollTo } from "./scroll.js";
import { moveToHistoryEnd } from "./history_end.js";
import { turnElements } from "./turn_range.js";

// How long the stage slides away (dock_reserve.js eases the history's
// bottom reserve as long).
export const FOLD_MS = 420;
// What opens a turn in the history: its prompt (data-turn-id), else a
// wake's or a reminder's note or /continue no's line (data-opening-id).
// reload_check.js reads it too.
export const OPENING = "[data-turn-id], [data-opening-id]";

// +stage+ and the slots the pieces leave (stage_dom.js: +promptSlot+,
// +extras+, +answer+, +timingSlot+, +tail+, +queuedSlot+); +historyEl+ and
// +historyNearBottom+(): the history and its follow check; +view+: the turn
// block (turn_block.js); +opener+: the turn opened in the history
// (stage_opened.js); +waiting+: the waiting cards (stage_waiting.js);
// +workingSet+: the page's working set or null; +isHolding+(), +ended+()
// (the end's kind, null: running), +isOpened+(), +promptEl+(): the stage's
// turn; +blockPlace+(el), +promptWords+(), +isCollapsed+(): the stage's
// reads; +releaseTurn+(), +clearStage+(): its lifecycle; +onHandedOff+:
// createStageView's.
export function createStageHandoff({
  stage, promptSlot, extras, answer, timingSlot, tail, queuedSlot, historyEl, historyNearBottom, view, opener, waiting,
  workingSet, isHolding, ended, isOpened, promptEl, blockPlace, promptWords, isCollapsed, releaseTurn, clearStage,
  onHandedOff,
}) {
  let folding = null; // { pieces, block, endKind, wasAtEnd, animate, immediate, opened, prompt } while it slides
  let foldTimer = null;

  // A fold cut short (the stage shows again): the slide's class goes.
  function cancelFold() {
    clearTimeout(foldTimer);
    foldTimer = null;
    stage.classList.remove("leaving");
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
  function handOff({ immediate = false } = {}) {
    if (folding && immediate) finishFold();
    if (!isHolding() || !ended()) return;
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
    const opened = isOpened();
    const prompt = promptEl();
    const pieces = handOffOrder({
      // The prompt still in its slot (an opened turn's is in the history).
      prompt: !opened && prompt?.parentNode === promptSlot ? prompt : null,
      block,
      extras: [...extras.children].map((el) => { el.classList.remove("ts-behind"); return el; }),
      answer: [...answer.children],
      timing: timingSlot.firstElementChild,
      kept: [...tail.children],
      queued: [...queuedSlot.children],
    });
    const animate = !immediate && !reducedMotion() && !document.hidden && !isCollapsed();
    folding = { pieces, block: blockEl, endKind: ended(), wasAtEnd: historyNearBottom(), animate, immediate, opened, prompt };
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

  return {
    handOff,
    finishFold,
    cancelFold,
    // A turn still sliding away gets into the history first.
    settle() {
      if (folding) finishFold();
    },
    isFolding: () => !!folding,
    // Another session opens, or this one renders again: a turn still
    // sliding away is dropped, never moved into whatever history shows now.
    reset() {
      folding = null;
      clearTimeout(foldTimer);
      foldTimer = null;
    },
  };
}
