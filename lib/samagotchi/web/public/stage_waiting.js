// The stage's waiting cards as data (stage_view.js, stage_asking.js): what
// waits in the stage, keyed by the card's id, never by its node (card.js
// drawCard may swap a plugin card's DIV for a DETAILS; a question card is
// drawn anew on a resync). Pure: no DOM but the key and kind read off a card
// as it arrives.
//
// Its feed: +arrive+ from stage_view.js place (a card the stage keeps),
// +settle+ from question_cards.js's resolve path (onSettled: answered,
// cancelled, replaced, removed; the continue card resolved or dropped; done:
// answered, cancelled or resolved for good, which removes its stored fold), from
// cards_place.js upsertCard for a plugin card redrawn without its actions,
// and from stage_view.js turnEnded for the warn cards leaving with the
// block; +reset+ from stage_view.js emptySlots. Settle is the one way out
// (nothing reads the slots back to drop an entry: the tests compare the two,
// stage_cuts_parity.test.js crossCheck and the e2e's stage check). Arrive is
// the one way in.
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
// how many cards waited when it was folded. That fold is this tab's own: it
// is kept in sessionStorage (one entry per session) so a reload or a resync
// mid-turn draws the card as the user left it, and it goes when that card is
// answered or cancelled (settle with done: no other card's answer touches
// it), when the fold drops, and when the turn hands off.
import { ASKS, PENDING, WARN_CARD } from "./stage_cards.js";
import { readSession, removeSession, writeSession } from "./storage.js";

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

// The asking card's fold, kept for this tab (docs/internals/web-frontend.md
// Storage keys): one entry per session, JSON {key, with}.
export const FOLD_PREFIX = "chi_asking_fold:";
export const foldKey = (sessionId) => (sessionId ? `${FOLD_PREFIX}${sessionId}` : null);

// The fold's storage: the guarded sessionStorage (storage.js); the specs
// inject their own, so one test's fold is not another's (they all use session
// s1 and the same question ids).
const tabStorage = {
  read: (key) => readSession(key),
  write: (key, value) => writeSession(key, value),
  remove: (key) => removeSession(key),
};

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

// +sessionId+: the open session (a getter, as app.js and the harnesses pass
// it); +storage+: the fold's read/write/remove, guarded (the specs inject
// their own).
export function createStageWaiting({ sessionId = null, storage = tabStorage } = {}) {
  const cards = new Map();
  let seq = 0;
  let folded = null;
  let foldedWith = 0;
  // The docked card the pager is on (null: the first).
  let paged = null;
  // The key this session's fold is stored under (null: no session, nothing
  // to keep).
  const at = () => foldKey(typeof sessionId === "function" ? sessionId() : sessionId);

  const entries = () => [...cards.entries()].sort((a, b) => rank(a[1].kind) - rank(b[1].kind) || a[1].order - b[1].order);
  const dockedKeys = () => entries().filter(([, e]) => e.docked).map(([key]) => key);

  // Cards that wait for the user: the blocking ones, with +asks+ the asking
  // ones too.
  function count({ asks = false } = {}) {
    let n = 0;
    for (const { kind } of cards.values()) if (BLOCKING.has(kind) || (asks && kind === "asks")) n += 1;
    return n;
  }

  // The fold this tab kept for the open session: {key, with}, or null (no
  // fold, nothing stored, or storage that can't be read).
  function storedFold() {
    const key = at();
    if (!key) return null;
    try {
      const value = JSON.parse(storage.read(key) || "null");
      return typeof value?.key === "string" ? { key: value.key, with: Number(value.with) || 0 } : null;
    } catch (_) {
      return null;
    }
  }

  // The stored fold says what the fold is: written with the count it was
  // made at, removed when there is no fold.
  function keepFold() {
    const key = at();
    if (!key) return;
    if (folded) storage.write(key, JSON.stringify({ key: folded, with: foldedWith }));
    else storage.remove(key);
  }

  return {
    // +key+ came to the stage (again: its kind and flags change, its place in
    // the order stays).
    // +summary+: the folded row's text from its data (card_kinds.js), null:
    // none (stage_asking.js foldedText reads the card then).
    arrive(key, { kind, docked = false, approval = false, summary = null } = {}) {
      if (!key || !KINDS.includes(kind)) return;
      const was = cards.get(key);
      // A new card goes in front of what the pager was on.
      if (!was) paged = null;
      cards.set(key, {
        kind, docked: !!docked, approval: !!approval, summary: typeof summary === "string" ? summary : null, order: was ? was.order : seq++,
      });
    },
    // +key+'s card was redrawn in place, still waiting (cards_place.js
    // upsertCard): its kind and summary as its data says now, its order and
    // docking as they were. Whether there was an entry to patch.
    update(key, { kind, summary = null } = {}) {
      const was = cards.get(key);
      if (!was) return false;
      cards.set(key, { ...was, kind: KINDS.includes(kind) ? kind : was.kind, summary: typeof summary === "string" ? summary : was.summary });
      return true;
    },
    // +key+ stopped waiting (+only+: when it is that kind). +done+: for
    // good (answered, cancelled, the continue card resolved): the fold this
    // tab kept goes when it names this card, also when the stage holds no
    // entry for it (a replay's earlier card, a history question).
    settle(key, { only = null, done = false } = {}) {
      if (done && key && storedFold()?.key === key) storage.remove(at());
      const was = cards.get(key);
      if (!was || (only && was.kind !== only)) return false;
      cards.delete(key);
      return true;
    },
    // The stage let its turn go: nothing waits, nothing is folded — the
    // stored fold stays: a resync replays the same turn, and the fold is the
    // user's.
    reset() {
      cards.clear();
      seq = 0;
      folded = null;
      foldedWith = 0;
      paged = null;
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
    // the blocking cards that wait now. Kept for this tab, so the same card
    // is folded again after a reload or a resync.
    fold(key) {
      folded = key ?? null;
      foldedWith = count();
      keepFold();
    },
    // The fold as it stands with +asking+ (the asking form's card key) now:
    // a card answered meanwhile lowers the mark, one more waiting than at
    // the fold drops it, and so does another form. The replay drew the card
    // the tab folded: with nothing folded in memory, that fold comes back.
    // The folded key, or null.
    trackFold(asking) {
      const now = count();
      // Nothing folded in memory and the replay drew the card this tab
      // folded (a reload, or a resync mid-turn): take that fold back.
      if (!folded) {
        const stored = storedFold();
        if (stored?.key === asking) { folded = stored.key; foldedWith = stored.with; }
      }
      foldedWith = Math.min(foldedWith, now);
      if (folded && (folded !== asking || now > foldedWith)) {
        folded = null;
        // Live unfolded it: a reload must not fold it again.
        keepFold();
      }
      return folded;
    },
    // The folded card is done for good (answered, cancelled, the turn handed
    // off): there is no fold to bring back.
    clearFold() {
      const key = at();
      if (key) storage.remove(key);
    },
    folded: () => folded,
  };
}
