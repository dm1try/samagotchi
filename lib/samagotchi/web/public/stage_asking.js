// The stage's docked card and its fold (stage_view.js wires it): a card that
// waits for the user (stage_cards.js PENDING but the step limit, or ASKS)
// opens the running turn in the history (stage_opened.js) and docks alone
// in the stage; chi's own question or approval after a reply gets that
// reply as its lead-in bubble. A waiting card has no toggle of its own (the
// stage's fold is the one); and the fold itself: the user's choice, a ref's
// reveal, and the docked card's own fold.
import { handOffOrder, stageCollapsed } from "./stage_model.js";
import { readStored, writeStored } from "./storage.js";
import { ASKS, PENDING, waitsInStage } from "./stage_cards.js";
import { cardIn, waitingKey } from "./stage_waiting.js";
import { warnDiffers } from "./card_kinds.js";

const COLLAPSE_KEY = "chi_stage_collapsed";
// The cards that get a lead-in bubble when their step wrote text: chi's own
// question and its own approval (question_cards.js data-kind; not a
// delegate's relayed one, a hook's question or the step limit).
const LEAD_IN_CARD = '.bubble.question[data-kind="question"]:not([data-relay]), .bubble.question[data-kind="approval"]:not([data-relay])';
// The step limit: its card goes under its ended turn (stage_view.js place),
// it never docks.
const STEP_LIMIT = '.bubble.continue, .bubble.question.step-limit, .bubble.question[data-kind="continue"]';

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
  // The docked card's fold is +waiting+'s (fold, trackFold): the waiting
  // card the user folded, by its key — kept for this tab (stage_waiting.js,
  // chi_asking_fold:<session>), so a reload or a resync mid-turn folds that
  // card again. For that card only: the next one arrives open, and when the
  // docked card goes the stage is as the choice and +revealed+ say. One more
  // card waiting since the fold (an approval, a relayed or hook question)
  // drops it, so the stage opens on it.

  // ── the docked card ──────────────────────────────────────────────────────

  // The step that asked +what+ ({kind, tool}: the card's data-kind and, for
  // an approval, the tool it approves): live, the step whose call runs
  // (turn_model.js askingText). In a replay (a reload, a resync) the asking
  // call may have completed before its question_requested comes
  // (TurnAccumulator.join_events: a question's always, an approval's once
  // it is answered), so the last step when one of its calls is the one
  // that asks (ask_user_question; the approved tool: a parallel call after
  // it doesn't hide it) and no card of this page took its reply yet. Live or replayed, a step whose reply a card already
  // took (+asked+) gives no other card its reply: a second approval or a
  // question after it in the same step has no lead-in. null: none.
  function askingGen({ kind = "question", tool = null } = {}) {
    const { turn } = view.current();
    const gen = turn && !turn.ended ? turn.gens[turn.gens.length - 1] : null;
    if (!gen?.text || asked.has(gen)) return null;
    if (view.askingText()) return gen;
    const call = kind === "question" ? "ask_user_question" : kind === "approval" ? tool : null;
    return call && gen.tools.some((row) => row.tool === call) ? gen : null;
  }
  // What a card asks, for askingGen.
  const asksOf = (el) => ({ kind: el?.dataset?.kind || "question", tool: el?.dataset?.tool || null });
  // The steps whose reply a question card took (place: question_cards.js
  // reads askingText right before), for askingGen's replay rule.
  const asked = new WeakSet();
  function askedFor(el) {
    const gen = askingGen(asksOf(el));
    if (gen) asked.add(gen);
  }

  // The reply that asked +pq+ (a pending question: its kind, an approval's
  // tool), "" for none.
  function askedText(pq = null) {
    return String(askingGen({ kind: pq?.kind || "question", tool: pq?.approval?.tool || null })?.text || "").trim();
  }

  // +el+ docks: a card that waits for the user (a pending question,
  // approval, relayed or hook card; an asking card), not the step limit,
  // placed while the turn runs.
  function docks(el) {
    if (isEnded() || !el?.matches) return false;
    if (el.matches(PENDING)) return !el.matches(STEP_LIMIT);
    return !!el.querySelector(ASKS);
  }

  // The lead-in for +el+: the reply that asked it when +el+ is chi's own
  // question or approval (LEAD_IN_CARD) and its step wrote text; "" otherwise.
  function leadInText(el) {
    if (!el.matches?.(LEAD_IN_CARD) || !el.matches(PENDING)) return "";
    return String(askingGen(asksOf(el))?.text || "").trim();
  }

  // The turn opens in the history (once): the prompt, the block (closed;
  // its steps in order from now on) and the rows the extras hold, in the
  // hand-off's order. What waits stays. +follow+: a reader who was at the
  // history's end follows it (a docked card with no lead-in; a lead-in's
  // read follows instead).
  function openTurn({ follow = false } = {}) {
    if (isOpened()) return;
    const { blockEl } = view.current();
    view.inOrder?.();
    setCloud(false);
    if (blockEl) {
      blockEl.open = false;
      // A lone step's block keeps its chrome there (index.html): its summary
      // is the way to the step's text, which no lead-in shows.
      blockEl.dataset.openedTurn = "";
    }
    const rows = [...extras.children].filter((el) => !waitsInStage(el));
    setOpened(true);
    opener.open(handOffOrder({ prompt: promptEl(), block: blockEl, extras: rows }), { follow });
  }

  // A no-op kept one release for a mixed cache (remove in the next one): a
  // stale stage_view.js (0.172.1's) calls it at the end of each refresh. The
  // drift check it ran is the tests' now (stage_cuts_parity.test.js
  // crossCheck, the e2e's stage check).
  function reconcileWaiting() {}

  // An opened turn's cards that stopped waiting go into the history: one
  // with a lead-in under it (also after the turn's end, so a card
  // cancelled by Stop turn sits there), another one at the history's end
  // while the turn runs.
  function settleCards() {
    if (!isOpened()) return;
    for (const el of [...extras.children]) {
      if (waitsInStage(el)) continue;
      // Out of the stage it waits behind nothing (stage_pager.js drawDocked).
      el.classList.remove("ts-behind");
      const key = waitingKey(el);
      if (opener.has(key)) opener.settle(key, el);
      else if (!isEnded()) opener.add(el);
    }
  }

  // The docked card the stage shows, by its key (the asking form: one at a
  // time, stage_waiting.js shown); null: none docked.
  function askingKey() {
    return waiting.shown();
  }
  function askingCard() {
    return cardIn(extras, askingKey());
  }

  // The folded row's text for the docked +card+ (stage_model.js
  // foldedRowText): a question's text, an approval's summary and its
  // command's first line, a plugin card's title; "" for none. From the
  // shown entry's data (stage_waiting.js summary), the card's own read the
  // cross-check, and the fallback for an entry without one.
  function foldedText(card) {
    if (!card) return "";
    const key = waitingKey(card);
    const summary = waiting.get(key)?.summary;
    const dom = foldedTextOf(card);
    if (summary == null) return dom;
    if (summary !== dom) warnDiffers("summary", key, summary, dom);
    return summary;
  }
  function foldedTextOf(card) {
    if (card.matches(".plugin-card")) return card.querySelector(".card-title")?.textContent || "";
    if (card.dataset.kind !== "approval") return card.querySelector(".question-text")?.textContent || "";
    // The summary's own words, not its "↑ its reason" link.
    const summary = card.querySelector(":scope > summary");
    const head = [...(summary?.childNodes || [])].filter((n) => n.nodeType === 3).map((n) => n.textContent).join("").trim();
    const what = (card.querySelector(".approval-what") || card.querySelector(".approval-tool"))?.textContent || "";
    return [head, what.trim().split("\n")[0].trim()].filter(Boolean).join(" ");
  }

  // The stage's card element for +key+ (its extras or its tail), null: none.
  function cardOf(key) {
    return cardIn(extras, key) || cardIn(tail, key);
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
    const waits = new Set();
    for (const key of waiting.blocking()) {
      const summary = cardOf(key)?.querySelector(":scope > summary");
      if (summary) waits.add(summary);
    }
    for (const summary of inert) {
      if (waits.has(summary)) continue;
      summary.removeAttribute("tabindex");
      inert.delete(summary);
    }
    for (const summary of waits) {
      if (inert.has(summary)) continue;
      summary.tabIndex = -1;
      inert.add(summary);
    }
  }

  // ── the fold ─────────────────────────────────────────────────────────────

  // Whether the stage is collapsed now (stage_model.js stageCollapsed).
  function isCollapsed() {
    return stageCollapsed({ choice, revealed, asking: askingKey(), askingFold: waiting.folded() });
  }

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
    const front = !value && pendingCard() ? cardOf(waiting.front()) : null;
    if (front) frame().afterGrowth(() => frame().reveal(front.parentElement));
  }

  return {
    askingGen, asksOf, askedFor, askedText, docks, leadInText, openTurn, reconcileWaiting, settleCards, askingCard, cardOf, foldedText, markOwnToggles,
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
