// The stage's asking form and its fold (stage_view.js wires it): the
// model's own question after a reply opens the running turn in the history
// (stage_opened.js), the card alone stays in the stage; a waiting card has
// no toggle of its own (the stage's fold is the one); and the fold itself:
// the user's choice, a ref's reveal, and the asking form's own fold.
import { handOffOrder, stageCollapsed } from "./stage_model.js";
import { readStored, writeStored } from "./storage.js";
import { PENDING, waitsInStage } from "./stage_cards.js";
import { cardIn, waitingKey, waitingKind } from "./stage_waiting.js";

const COLLAPSE_KEY = "chi_stage_collapsed";
// The model's own question (question_cards.js data-kind; not an approval,
// the step limit, a hook's question or a delegate's relayed one): the one
// card whose asking text opens the turn in the history (stage_opened.js).
const ASK_CARD = '.bubble.question[data-kind="question"]:not([data-relay])';

function readCollapsed() {
  return readStored(COLLAPSE_KEY) === "1";
}

// +stage+, +extras+, +tail+, +scroller+ and +fold+: the stage's root, its
// two card slots, its scroller and its fold button. +view+: the turn block
// (turn_block.js); +opener+: the opened turn (stage_opened.js); +frame()+:
// the stage's frame (stage_frame.js, made after this). +isOpened()+ /
// +setOpened(v)+: whether the turn is opened in the history; +isEnded()+:
// the turn has ended; +promptEl()+: the turn's prompt bubble; +setCloud(open)+:
// the cloud; +scheduleRefresh()+; +pendingCard()+: a card waits in the card
// slots; +waiting+: the stage's waiting cards as data (stage_waiting.js),
// which say the asking form's card and hold its fold.
export function createStageAsking({
  stage, extras, tail, scroller, fold, view, opener, frame, isOpened, setOpened, isEnded, promptEl, setCloud,
  scheduleRefresh, pendingCard, waiting,
}) {
  // The user's own fold (chi_stage_collapsed), in memory: written on a
  // hand toggle, never read back from storage to decide (another tab's
  // write doesn't apply live).
  let choice = readCollapsed();
  // A ref's "show in turn" opened a collapsed stage (not kept).
  let revealed = false;
  // The asking form's fold is +waiting+'s (fold, trackFold): the waiting
  // card the user folded, by its key. For that question only, never saved:
  // the next one arrives open, and when the form ends the stage is as the
  // choice and +revealed+ say. One more card waiting since the fold (an
  // approval, a relayed or hook question) drops it, so the stage opens on it.

  // ── the asking form ──────────────────────────────────────────────────────

  // The step that asked the turn's question: live, the step whose call
  // runs (turn_model.js askingText); in a replay (a reload, a resync) the
  // asking call has already completed when its question_requested comes
  // (TurnAccumulator.join_events), so the last step when its last call is
  // ask_user_question and no card of this page took its reply yet (+asked+:
  // a later card, another kind's, never reuses it). null: none.
  function askingGen() {
    const { turn } = view.current();
    const gen = turn && !turn.ended ? turn.gens[turn.gens.length - 1] : null;
    if (!gen?.text) return null;
    if (view.askingText()) return gen;
    return gen.tools[gen.tools.length - 1]?.tool === "ask_user_question" && !asked.has(gen) ? gen : null;
  }
  // The steps whose reply a question card took (place: question_cards.js
  // reads askingText right before), for askingGen's replay rule.
  const asked = new WeakSet();
  function askedFor() {
    const gen = askingGen();
    if (gen) asked.add(gen);
  }

  // The reply that asked the question, "" for none.
  function askedText() {
    return String(askingGen()?.text || "").trim();
  }

  // The reply that asked +el+ when +el+ is the model's own question and
  // there is one (the promotion rule: ASK_CARD, in the extras, a reply
  // before it); "" otherwise.
  function promotedText(el) {
    if (!el.matches?.(ASK_CARD) || !el.matches(PENDING)) return "";
    return askedText();
  }

  // The turn opens in the history (once): the prompt, the block (closed;
  // its steps in order from now on) and the rows the extras hold, in the
  // hand-off's order. What waits stays.
  function openTurn() {
    if (isOpened()) return;
    const { blockEl } = view.current();
    view.inOrder?.();
    setCloud(false);
    if (blockEl) blockEl.open = false;
    const rows = [...extras.children].filter((el) => !waitsInStage(el));
    setOpened(true);
    opener.open(handOffOrder({ prompt: promptEl(), block: blockEl, extras: rows }));
  }

  // The waiting cards as data, checked against the slots (stage_waiting.js
  // reconcile, its second feed: it only settles): a card gone from the
  // extras and the tail, or no longer waiting, settles, also one answered
  // outside question_cards.js's hook.
  function reconcileWaiting() {
    waiting.reconcile((key) => !!waitingKind(cardIn(extras, key) || cardIn(tail, key)));
  }

  // An opened turn's cards that stopped waiting go into the history: a
  // promoted one under its reason (also after the turn's end, so a card
  // cancelled by Stop turn sits there), another one at the history's end
  // while the turn runs.
  function settleCards() {
    if (!isOpened()) return;
    for (const el of [...extras.children]) {
      if (waitsInStage(el)) continue;
      const key = waitingKey(el);
      if (opener.has(key)) opener.settle(key, el);
      else if (!isEnded()) opener.add(el);
    }
  }

  // The asking form's card: a docked card that waits (a promoted one: its
  // reply is the reason bubble in the history), by its key; null: no asking
  // form.
  function askingKey() {
    return waiting.docked()[0] || null;
  }
  function askingCard() {
    return cardIn(extras, askingKey());
  }

  // A card that waits in the stage has no toggle of its own: the stage's
  // fold is the one (a closed card left an empty box). A click on its
  // summary (Enter and Space on one arrive as a click) doesn't toggle it,
  // and question_cards.js reads the refusal (defaultPrevented): no
  // data-toggled. Not stopped: the page's outside-click closers still see
  // it. A button or link in the summary ("↑ its reason") works as ever.
  // The test is "waits now", at the click: an answered card toggles.
  stage.addEventListener("click", (e) => {
    const summary = e.target.closest?.("summary");
    if (!summary || summary.contains(e.target.closest("button, a"))) return;
    if (summary.parentElement?.matches(PENDING)) e.preventDefault();
  }, true);
  // Its summary isn't a control meanwhile: out of the tab order (the CSS
  // drops its mark and pointer). Not aria-disabled: that would disable the
  // buttons in it too. +inert+: the ones marked, given back once their card
  // stops waiting or leaves.
  const inert = new Set();
  function markOwnToggles() {
    const waiting = new Set();
    for (const el of [...extras.querySelectorAll(PENDING), ...tail.querySelectorAll(PENDING)]) {
      const summary = el.querySelector(":scope > summary");
      if (summary) waiting.add(summary);
    }
    for (const summary of inert) {
      if (waiting.has(summary)) continue;
      summary.removeAttribute("tabindex");
      inert.delete(summary);
    }
    for (const summary of waiting) {
      if (inert.has(summary)) continue;
      summary.tabIndex = -1;
      inert.add(summary);
    }
  }

  // ── the fold ─────────────────────────────────────────────────────────────

  // Whether the stage is collapsed now (stage_model.js stageCollapsed).
  const isCollapsed = () => stageCollapsed({ choice, revealed, asking: askingKey(), askingFold: waiting.folded() });

  // Its fold is that card's only; the form's start opens a stage saved as
  // collapsed and its end gives the choice back, in this task (the card's
  // focus lands right after the start: question_cards.js focusWhenIdle).
  // Another card that comes to wait meanwhile opens it: nothing waits
  // unseen behind the folded question.
  // A card answered meanwhile lowers the mark, so the next one opens it too.
  function trackFold() {
    waiting.trackFold(askingKey());
  }

  // The fold as isCollapsed says, only when it changed (+force+: always):
  // idempotent, and no refresh of its own (refresh calls it).
  function drawCollapsed({ force = false } = {}) {
    const collapsed = isCollapsed();
    if (!force && fold.textContent && stage.classList.contains("collapsed") === collapsed) return;
    stage.classList.toggle("collapsed", collapsed);
    scroller.hidden = collapsed;
    fold.textContent = collapsed ? "▴" : "▾";
    fold.setAttribute("aria-label", collapsed ? "Expand the running turn" : "Collapse the running turn to its status");
    fold.setAttribute("aria-expanded", String(!collapsed));
    frame().fitCap();
  }

  function applyCollapsed() {
    drawCollapsed({ force: true });
    scheduleRefresh();
  }

  // A hand toggle (the fold button, a tap on the folded row). In the
  // asking form it folds that question only and writes nothing; else it is
  // the user's choice, kept.
  function setCollapsed(value) {
    const asking = askingKey();
    if (asking) {
      waiting.fold(value ? asking : null);
    } else {
      choice = value;
      revealed = false;
      writeStored(COLLAPSE_KEY, value ? "1" : "0");
    }
    applyCollapsed();
    // Opened on a waiting card: it shows as it does on arrival.
    if (!value && pendingCard()) frame().afterGrowth(() => frame().reveal(tail.querySelector(PENDING) ? tail : extras));
  }

  return {
    askingGen, askedFor, askedText, promotedText, openTurn, reconcileWaiting, settleCards, askingCard, markOwnToggles,
    isCollapsed, trackFold, drawCollapsed, applyCollapsed, setCollapsed,
    // A ref's "show in turn" opens a collapsed stage for this turn only.
    reveal() {
      revealed = true;
      applyCollapsed();
    },
    // The stage cleared: a reveal ends with it.
    unreveal() {
      if (!revealed) return;
      revealed = false;
      applyCollapsed();
    },
  };
}
