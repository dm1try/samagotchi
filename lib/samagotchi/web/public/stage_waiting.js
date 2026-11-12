// The stage's waiting cards as data (stage_view.js, stage_asking.js): what
// waits in the stage, keyed by the card's id, never by its node (card.js
// drawCard may swap a plugin card's DIV for a DETAILS; a question card is
// drawn anew on a resync). Pure: no DOM but the key and kind read off a card
// as it arrives.
//
// Its feed: +arrive+ from stage_view.js place (a card the stage keeps),
// +settle+ from question_cards.js's resolve path (onSettled: answered,
// cancelled, replaced, removed; the continue card resolved or dropped), from
// cards_place.js upsertCard for a plugin card redrawn without its actions,
// and from stage_view.js turnEnded for the warn cards leaving with the
// block; +reset+ from stage_view.js emptySlots. A second feed only settles:
// +reconcile+ (stage_asking.js: at each refresh, and before the fold, the
// blocking read and an opened row) drops an entry whose card
// is gone or waits no more, for a card answered outside question_cards.js
// (the stage's unit tests answer a card by its classes alone). It never
// adds or docks: arrive is the one way in.
//
// A card's entry: its kind (KINDS), docked (it shows alone in the box above
// the composer, its turn opened in the history: stage_asking.js docks; its
// lead-in bubble is stage_opened.js's, by the same key), whether it is an
// approval (a delegate's relayed one too: raiseForApproval) and its arrival
// order. The order the stage shows them in: blocking cards first, then the
// asking ones (and the warnings), each in arrival order, so a live page and
// a reload agree whatever order the replay brings them in. One docked card
// shows at a time (+shown+: the one the pager is on, else the first). The
// fold (the docked card's own, stage_asking.js) is the folded card's key and
// how many cards waited when it was folded.
import { ASKS, PENDING, WARN_CARD } from "./stage_cards.js";

// The kinds: what blocks the turn (BLOCKING), a running turn's card with
// actions (check-in: "asks"), a plugin's warning ("warn": stays in sight,
// waits for nobody).
export const KINDS = ["question", "approval", "relay", "hook", "continue", "asks", "warn"];
const BLOCKING = new Set(["question", "approval", "relay", "hook", "continue"]);
// +kind+ stops the turn until the user answers.
export const isBlocking = (kind) => BLOCKING.has(kind);
// An approval card (question_cards.js data-kind), a delegate's relayed one too.
const APPROVAL_CARD = '.bubble.question[data-kind="approval"]';
export const isApprovalCard = (el) => !!el?.matches?.(APPROVAL_CARD);

// The old continue card has no id: one at a time.
export const CONTINUE_KEY = "continue";

// A question card's key (its data-qid), a plugin card's (its data-card-id).
export const questionKey = (qid) => (qid == null ? null : `q:${qid}`);
export const pluginCardKey = (id) => (id == null || id === "" ? null : `c:${id}`);

// +el+'s key, null: not a card the stage keeps.
export function waitingKey(el) {
  if (!el?.matches) return null;
  if (el.matches(".bubble.question")) return questionKey(el.dataset.qid);
  if (el.matches(".bubble.continue")) return CONTINUE_KEY;
  if (el.matches(".plugin-card")) return pluginCardKey(el.dataset.cardId);
  return null;
}

// +el+'s kind (KINDS), null: none (it doesn't wait in the stage).
export function waitingKind(el) {
  if (!el?.matches) return null;
  if (el.matches(PENDING)) {
    if (el.matches(".bubble.continue, .step-limit") || el.dataset.kind === "continue") return "continue";
    if (el.dataset.relay) return "relay";
    if (el.dataset.kind === "approval") return "approval";
    if (el.dataset.kind === "hook") return "hook";
    return "question";
  }
  if (el.querySelector?.(ASKS)) return "asks";
  if (el.matches(WARN_CARD)) return "warn";
  return null;
}

// +root+'s child card with +key+ (the stage's extras or tail), null: none.
export function cardIn(root, key) {
  if (!root || !key) return null;
  return [...root.children].find((el) => waitingKey(el) === key) || null;
}

// +kind+'s rank in the stage's order: blocking cards before the rest.
const rank = (kind) => (BLOCKING.has(kind) ? 0 : 1);

export function createStageWaiting() {
  const cards = new Map();
  let seq = 0;
  let folded = null;
  let foldedWith = 0;
  // The docked card the pager is on (null: the first).
  let paged = null;

  const entries = () => [...cards.entries()].sort((a, b) => rank(a[1].kind) - rank(b[1].kind) || a[1].order - b[1].order);
  const dockedKeys = () => entries().filter(([, e]) => e.docked).map(([key]) => key);

  // Cards that wait for the user: the blocking ones, with +asks+ the asking
  // ones too.
  function count({ asks = false } = {}) {
    let n = 0;
    for (const { kind } of cards.values()) if (BLOCKING.has(kind) || (asks && kind === "asks")) n += 1;
    return n;
  }

  return {
    // +key+ came to the stage (again: its kind and flags change, its place in
    // the order stays).
    arrive(key, { kind, docked = false, approval = false } = {}) {
      if (!key || !KINDS.includes(kind)) return;
      const was = cards.get(key);
      // A new card goes in front of what the pager was on.
      if (!was) paged = null;
      cards.set(key, {
        kind, docked: !!docked, approval: !!approval, order: was ? was.order : seq++,
      });
    },
    // +key+ stopped waiting (+only+: when it is that kind).
    settle(key, { only = null } = {}) {
      const was = cards.get(key);
      if (!was || (only && was.kind !== only)) return false;
      cards.delete(key);
      return true;
    },
    // The stage let its turn go: nothing waits, nothing is folded.
    reset() {
      cards.clear();
      seq = 0;
      folded = null;
      foldedWith = 0;
      paged = null;
    },
    // The second feed: every entry +waits+(key, kind) says no to settles.
    reconcile(waits) {
      for (const [key, { kind }] of [...cards.entries()]) if (!waits(key, kind)) cards.delete(key);
    },
    has: (key) => cards.has(key),
    get: (key) => (cards.has(key) ? { key, ...cards.get(key) } : null),
    // The docked cards' keys, in the stage's order.
    docked: dockedKeys,
    // The docked card the stage shows: the one the pager is on while it is
    // docked, else the first (blocking before asking); null: none.
    shown() {
      const keys = dockedKeys();
      return keys.includes(paged) ? paged : keys[0] ?? null;
    },
    // The pager: the docked card +by+ places from the shown one (clamped).
    // The shown key, or null.
    page(by) {
      const keys = dockedKeys();
      if (!keys.length) return null;
      const at = Math.max(0, keys.indexOf(keys.includes(paged) ? paged : keys[0]));
      paged = keys[Math.min(keys.length - 1, Math.max(0, at + by))];
      return paged;
    },
    // The card in front: the first blocking one, else the first asking one;
    // null: none.
    front() {
      const list = entries();
      const hit = list.find(([, e]) => BLOCKING.has(e.kind)) || list.find(([, e]) => e.kind === "asks");
      return hit ? hit[0] : null;
    },
    count,
    // The blocking cards' keys, in order.
    blocking: () => entries().filter(([, e]) => BLOCKING.has(e.kind)).map(([key]) => key),
    // Every entry in the stage's order (the tests' and the harness's read).
    list: () => entries().map(([key, e]) => ({ key, ...e })),
    // The asking form's fold: +key+ folded by hand (null: unfolded), with
    // the blocking cards that wait now.
    fold(key) {
      folded = key ?? null;
      foldedWith = count();
    },
    // The fold as it stands with +asking+ (the asking form's card key) now:
    // a card answered meanwhile lowers the mark, one more waiting than at
    // the fold drops it, and so does another form. The folded key, or null.
    trackFold(asking) {
      const now = count();
      foldedWith = Math.min(foldedWith, now);
      if (folded && (folded !== asking || now > foldedWith)) folded = null;
      return folded;
    },
    folded: () => folded,
  };
}
