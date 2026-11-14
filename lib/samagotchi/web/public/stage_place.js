// Where a row or a card goes while the stage holds a turn (stage_view.js's
// place, wired there): the stage's extras or its tail, its queued slot, the
// history's end of a turn opened there, or the history itself (false). A card
// that waits for the user docks: the turn opens in the history (stage_asking.js
// openTurn), its lead-in lands there in the card's task (stage_opened.js), the
// card waits in the stage (stage_waiting.js arrive). The step limit's card
// hands the turn off at once (stage_handoff.js). What a card waits as comes
// from its data (card_kinds.js, +expect+ right before its place); the node's
// own read (waitingKind) is the cross-check, and the fallback for a card
// that came without it (an older question_cards.js, a test's bare card).
import { placeFor, placeKind } from "./stage_model.js";
import { askingRefs } from "./turn_model.js";
import { ASKS, PENDING } from "./stage_cards.js";
import { isApprovalCard, isBlocking, waitingKey, waitingKind } from "./stage_waiting.js";
import { warnDiffers } from "./card_kinds.js";

// +historyEl+, +extras+, +tail+, +queuedSlot+: the history and the stage's
// slots; +ensureQueuedSlot()+ puts the queued slot back in the stage.
// +handoff+ (stage_handoff.js), +quiet+ (stage_quiet_clock.js), +view+ (the
// turn block), +opener+ (stage_opened.js), +waiting+ (stage_waiting.js) and
// +ask+ (stage_asking.js, whole: the docking, the lead-in, the opened row).
// +frame()+: the stage's frame (stage_frame.js); +refresh()+ and
// +scheduleRefresh()+ the stage's; +holding()+, +opened()+, +endKind()+ and
// +promptEl()+ the stage's turn; +historyNearBottom()+ the history's follow
// check.
export function createStagePlace({
  historyEl, extras, tail, queuedSlot, ensureQueuedSlot, handoff, quiet, view, opener, waiting, ask, frame, refresh,
  scheduleRefresh, holding, opened, endKind, promptEl, historyNearBottom,
}) {
  // key → what the card about to be placed waits as ({kind, approval,
  // summary}): taken by its place, whatever the outcome (a history card's
  // too), cleared with the stage's slots (reset).
  const expected = new Map();

  // The card's wait: its data, else the node's read; the two checked
  // against each other.
  function waitOf(el, key) {
    const data = key ? expected.get(key) : undefined;
    if (key) expected.delete(key);
    const dom = { kind: waitingKind(el), approval: isApprovalCard(el) };
    if (!data) return { ...dom, summary: null };
    if ((data.kind ?? null) !== dom.kind || !!data.approval !== dom.approval) warnDiffers("kind", key, data, dom);
    return { kind: data.kind ?? null, approval: !!data.approval, summary: data.summary ?? null };
  }

  // The stage's extras while it holds a turn (a card, a prompt for its
  // next step, a command, a note, the end line), its queued slot for a
  // line queued for after it; false: the history takes it.
  function place(el) {
    // A turn still sliding away goes into the history first: what comes
    // now comes after it.
    handoff.settle();
    const key = waitingKey(el);
    const wait = waitOf(el, key);
    const waits = !!(el.matches?.(PENDING) || el.querySelector?.(ASKS));
    const kind = placeKind(el);
    const isOpened = opened();
    const ended = endKind();
    const where = placeFor({ live: holding(), handingOff: false, kind, opened: isOpened && !ended });
    // A late recap (idle-only, it describes the chat before this turn)
    // goes above an opened turn, not inside it.
    const above = kind === "recap" && isOpened ? [promptEl(), view.current().blockEl].find((x) => x?.parentElement === historyEl) : null;
    if (above) {
      historyEl.insertBefore(el, above);
      return true;
    }
    if (where === "history") return false;
    quiet.alive();
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
      ask.settleCards();
      opener.add(el);
      scheduleRefresh();
      return true;
    }
    // A card that waits for the user docks: the turn opens in the
    // history, a lead-in lands there in this task, the card stays here.
    const docked = ask.docks(el);
    // A card drawn again with its key (the same question) keeps its lead-in.
    const kept = docked && opener.has(key);
    const reason = docked && !kept ? ask.leadInText(el) : "";
    // Read before the turn's pieces make the history taller: with no
    // lead-in to read, a reader at the end follows the turn's move.
    const atEnd = docked ? historyNearBottom() : false;
    if (docked) ask.openTurn({ follow: atEnd && !reason });
    const slot = ended ? tail : extras;
    const stick = slot.scrollHeight - slot.scrollTop - slot.clientHeight < 24;
    // The stage's order (stage_waiting.js): a card that blocks goes before
    // the asking ones, as a reload places them.
    const behind = isBlocking(wait.kind) ? [...slot.children].find((x) => waiting.get(waitingKey(x))?.kind === "asks") : null;
    slot.insertBefore(el, behind || null);
    slot.hidden = false;
    // The card is the stage's to keep (stage_waiting.js): docked when it
    // waits for the user (its lead-in is the opener's, by the same key).
    const waitKind = wait.kind;
    if (waitKind) waiting.arrive(key, { kind: waitKind, docked, approval: wait.approval, summary: wait.summary });
    if (stick || waits) slot.scrollTop = slot.scrollHeight;
    if (kept) opener.relink(key, el);
    if (reason) {
      const { turn } = view.current();
      opener.ask({
        card: el, key, text: reason, refs: askingRefs(turn) || ask.askingGen(ask.asksOf(el))?.refs || null, step: turn?.gens.length || 0,
        turnId: promptEl()?.dataset.turnId || null, questionId: el.dataset.qid ?? null, follow: atEnd,
      });
    }
    // The step limit: its card goes under its ended turn in the
    // conversation at once, as a reload draws it (the hand-off: its fold,
    // the history's follow and the reload check as for any finished turn;
    // the in-use watch and the end read don't hold it).
    if (ended && waitKind === "continue") {
      handoff.handOff();
      return true;
    }
    // A waiting card and the asking form (refresh) land in one task.
    if (waits) refresh();
    else scheduleRefresh();
    // The asking form: the stage shrinks to the card; an answer can also
    // shrink it to a remaining card, or release it at the next step.
    if (docked) frame().forgetContent();
    if (waits && el.matches?.(".bubble.question")) ask.askedFor(el);
    // A card that waits for the user is brought into the stage's view: in
    // a short window the prompt and headline fill it and the card sat
    // below, out of sight (once the stage has grown for it).
    if (waits) frame().afterGrowth(() => frame().reveal(slot));
    return true;
  }

  return {
    place,
    // +key+'s card is placed next; +info+: card_kinds.js's wait.
    expect(key, info) {
      if (key && info) expected.set(key, info);
    },
    reset: () => expected.clear(),
  };
}
