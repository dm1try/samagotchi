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
// +reconcile+ (stage_asking.js, at each refresh) drops an entry whose card
// is gone or waits no more, for a card answered outside question_cards.js
// (the stage's unit tests answer a card by its classes alone). It never
// adds or docks: arrive is the one way in.
//
// A card's entry: its kind (KINDS), docked (it shows the asking form: today
// a model's own question with a reply before it, stage_asking.js
// promotedText), its lead-in (the reason bubble's question id, null: none)
// and its arrival order. The fold (the asking form's own, stage_asking.js)
// is the folded card's key and how many cards waited when it was folded.
import { ASKS, PENDING, WARN_CARD } from "./stage_cards.js";

// The kinds: what blocks the turn (BLOCKING), a running turn's card with
// actions (check-in: "asks"), a plugin's warning ("warn": stays in sight,
// waits for nobody).
export const KINDS = ["question", "approval", "relay", "hook", "continue", "asks", "warn"];
const BLOCKING = new Set(["question", "approval", "relay", "hook", "continue"]);

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

export function createStageWaiting() {
  const cards = new Map();
  let seq = 0;
  let folded = null;
  let foldedWith = 0;

  const entries = () => [...cards.entries()].sort((a, b) => a[1].order - b[1].order);

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
    arrive(key, { kind, docked = false, leadIn = null } = {}) {
      if (!key || !KINDS.includes(kind)) return;
      const was = cards.get(key);
      cards.set(key, { kind, docked: !!docked, leadIn: leadIn == null ? null : String(leadIn), order: was ? was.order : seq++ });
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
    },
    // The second feed: every entry +waits+(key, kind) says no to settles.
    reconcile(waits) {
      for (const [key, { kind }] of [...cards.entries()]) if (!waits(key, kind)) cards.delete(key);
    },
    has: (key) => cards.has(key),
    get: (key) => (cards.has(key) ? { key, ...cards.get(key) } : null),
    // The docked cards' keys, in arrival order.
    docked: () => entries().filter(([, e]) => e.docked).map(([key]) => key),
    // The card in front: the first blocking one, else the first asking one;
    // null: none.
    front() {
      const list = entries();
      const hit = list.find(([, e]) => BLOCKING.has(e.kind)) || list.find(([, e]) => e.kind === "asks");
      return hit ? hit[0] : null;
    },
    count,
    // Every entry in arrival order (the tests' and the harness's read).
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
