// The open session's cards as data (A2 step 1): every question, continue
// offer and plugin card the page heard of, keyed as stage_waiting.js keys
// them (q:<id>, c:<id>, continue), with what it waits as (card_kinds.js) and
// where it stands. An observer: fed by the stream's card events
// (observeCards, around app.js's stream handlers, so a snapshot's replay
// feeds it too) and by a read (+seed+, session_view.js renderSessionView,
// right before the replay); reset when the page leaves the session
// (forgetSession). Its one reader is the opt-in reload check
// (reload_check.js): the turn's entries live against a registry seeded from a
// fresh read. Nothing on the page draws from it. Pure: no DOM.
//
// An entry: {key, kind, status, of_turn, opening_id, step, relayed_to,
// summary, actions?}. +status+: pending, answered, cancelled (questions),
// pending, resolved, dropped (the continue offer: dropped when the step
// limit's own question asks the same), asks / shown (a plugin card with or
// without actions it waits on). +of_turn+: the turn the card is a row of (a
// read's CardStore of_turn; live, the running turn's id when the card came
// in it: a live card or question carries none). +step+: {iteration, calls}
// of that turn when it came (CardStore's place), null outside a turn.
//
// Idempotent: an event or a read applied on an existing key merges; a final
// status (answered, cancelled, resolved, dropped) never goes back to pending
// (but the continue key, which has no id: a new offer after a resolved one
// is a new card); of_turn, opening_id and step keep the first non-null. So a
// read seeded then its replay applied is the registry live had at that point
// (card_registry.test.js, every stage cut).
//
// The turn's end: a question still pending when its turn ends is cancelled
// (session_view.js endTurnView cancels its card on the page, no event comes;
// CardStore lists it with neither answer nor cancel, and +seed+ reads such
// an entry of a turn that isn't running as cancelled too).
import { cardWait, continueWait, questionWait } from "./card_kinds.js";
import { measured, probing } from "./stage_probe.js";

const FINAL = new Set(["answered", "cancelled", "resolved", "dropped"]);
const CONTINUE_KEY = "continue";
const questionKey = (id) => (id == null || id === "" ? null : `q:${id}`);
const cardKey = (id) => (id == null || id === "" ? null : `c:${id}`);
const TURN_ENDS = ["turn_completed", "turn_canceled", "turn_failed"];

// The card events the registry takes (observeCards wraps these).
export const CARD_EVENTS = [
  "turn_started", ...TURN_ENDS, "generation_started", "tool_call_started",
  "question_requested", "question_answered", "question_cancelled", "question_relay",
  "continue_offered", "continue_resolved", "card",
];

// A card's actions as the entry keeps them: label and command only.
const actionsOf = (card) => (Array.isArray(card?.actions) ? card.actions.filter(Boolean).map((a) => ({ label: a.label ?? null, command: a.command ?? null })) : []);

export function createCardRegistry() {
  const entries = new Map();
  // The running turn (its id, null: none, or an older worker's turn with
  // none) and the step it is on.
  let turn = null;
  let running = false;
  let step = null;

  const firstOf = (was, now) => (was ?? now ?? null);

  // +key+ as +patch+ says (its undefined fields left out), merged into what
  // was there.
  function put(key, given) {
    if (!key) return;
    const patch = Object.fromEntries(Object.entries(given).filter(([, v]) => v !== undefined));
    const was = entries.get(key);
    if (!was) {
      entries.set(key, {
        key, kind: null, status: "pending", of_turn: null, opening_id: null, step: null, relayed_to: null, summary: "", ...patch,
      });
      return;
    }
    const status = FINAL.has(was.status) && !FINAL.has(patch.status ?? was.status) ? was.status : patch.status ?? was.status;
    entries.set(key, {
      ...was, ...patch, status,
      of_turn: firstOf(was.of_turn, patch.of_turn), opening_id: firstOf(was.opening_id, patch.opening_id), step: firstOf(was.step, patch.step),
    });
  }

  // A question's entry from its pending question (+pq+), with +extra+.
  function putQuestion(pq, extra = {}) {
    const key = questionKey(pq?.id);
    if (!key) return;
    const { kind, summary } = questionWait(pq);
    const relayed = "relayed_to" in (pq || {}) ? { relayed_to: pq.relayed_to || null } : {};
    put(key, { kind, summary, ...relayed, ...extra });
    // The step limit's question asks what the old continue card asks.
    if (kind === "continue") dropContinue();
  }

  function dropContinue() {
    const was = entries.get(CONTINUE_KEY);
    if (was && was.status === "pending") entries.set(CONTINUE_KEY, { ...was, status: "dropped" });
  }

  const pendingContinueQuestion = () => [...entries.values()].some((e) => e.kind === "continue" && e.key !== CONTINUE_KEY && e.status === "pending");

  function putContinue(offer) {
    const was = entries.get(CONTINUE_KEY);
    // No id: a new offer after a settled one is a new card.
    if (was && FINAL.has(was.status) && was.status !== "dropped") entries.delete(CONTINUE_KEY);
    const { kind, summary } = continueWait(offer);
    put(CONTINUE_KEY, { kind, summary, status: "pending" });
    if (pendingContinueQuestion()) dropContinue();
  }

  // A plugin card (+card+: a live card event or a read's entry).
  function putCard(card, extra = {}) {
    const key = cardKey(card?.id);
    if (!key) return;
    const { kind, summary } = cardWait(card);
    put(key, { kind, summary, status: kind === "asks" ? "asks" : "shown", actions: actionsOf(card), ...extra });
  }

  // Live: a card of the running turn takes the turn's id and its step.
  const liveTurnOf = (inTurn) => (inTurn && running ? { of_turn: turn, step } : {});

  function endTurn(data) {
    const ended = data?.turn_id || turn;
    if (ended) {
      for (const e of entries.values()) {
        if (e.of_turn === ended && e.status === "pending" && e.key.startsWith("q:")) entries.set(e.key, { ...e, status: "cancelled" });
      }
    }
    turn = null;
    running = false;
    step = null;
  }

  // Only a question the registry knows (its request or a read listed it).
  function settleQuestion(id, status) {
    const key = questionKey(id);
    if (key && entries.has(key)) put(key, { status });
  }

  const APPLY = {
    turn_started: (data) => {
      turn = data?.turn_id || null;
      running = true;
      step = null;
    },
    turn_completed: endTurn,
    turn_canceled: endTurn,
    turn_failed: endTurn,
    generation_started: (data) => {
      if (running) step = { iteration: data?.iteration ?? null, calls: 0 };
    },
    tool_call_started: (data) => {
      if (running) step = { iteration: data?.iteration ?? step?.iteration ?? null, calls: Number(data?.call_index) || 0 };
    },
    question_requested: (data) => {
      const pq = data?.pending_question;
      if (pq?.id) putQuestion(pq, liveTurnOf(true));
    },
    question_answered: (data) => settleQuestion(data?.id, "answered"),
    question_cancelled: (data) => settleQuestion(data?.id, "cancelled"),
    question_relay: (data) => {
      const key = questionKey(data?.id);
      if (key && entries.has(key)) put(key, { relayed_to: data.relayed_to || null });
    },
    continue_offered: (data) => putContinue(data),
    continue_resolved: () => {
      if (entries.has(CONTINUE_KEY) && entries.get(CONTINUE_KEY).status === "pending") put(CONTINUE_KEY, { status: "resolved" });
    },
    card: (data) => putCard(data, liveTurnOf(!!data?.in_turn)),
  };

  // A read's question entry (CardStore: its pending question, answer or
  // cancel; of_turn, opening_id, its step).
  function seedQuestion(entry, runningId) {
    const pq = entry.pending_question;
    const status = entry.answer ? "answered" : entry.cancelled ? "cancelled"
      // Neither: open while its turn runs, else its turn ended on it.
      : entry.current || (entry.of_turn && entry.of_turn === runningId) ? "pending" : "cancelled";
    putQuestion(pq, { status, ...placeOf(entry) });
  }

  const placeOf = (entry) => ({
    of_turn: entry.of_turn ?? null,
    opening_id: entry.opening_id ?? null,
    step: entry.iteration == null ? null : { iteration: entry.iteration, calls: Number(entry.calls) || 0 },
  });

  function seedFrom(read) {
    entries.clear();
    const runningId = read?.current_turn ? read.current_turn.turn_id || null : null;
    turn = runningId;
    running = !!read?.current_turn;
    step = null;
    for (const entry of Array.isArray(read?.cards) ? read.cards : []) {
      if (entry?.type === "question" && entry.pending_question?.id) seedQuestion(entry, runningId);
      else if (entry?.type === "card") putCard(entry, placeOf(entry));
    }
    const pq = read?.pending_question;
    if (pq?.id && pq.status === "pending") putQuestion(pq, { status: "pending" });
    if (read?.continue_offer) putContinue(read.continue_offer);
  }

  return {
    // One stream event (+type+, +data+), as observeCards hands them.
    apply(type, data) {
      APPLY[type]?.(data || {});
    },
    // A read of the session (the full GET, or a stage cut's show): its
    // CardStore listing, its pending question and continue offer. Replaces
    // what was there.
    seed(read) {
      measured("cards:seed", () => seedFrom(read));
      return this;
    },
    reset() {
      entries.clear();
      turn = null;
      running = false;
      step = null;
    },
    get: (key) => (entries.has(key) ? { ...entries.get(key) } : null),
    // Every entry, in the order the registry first heard of it.
    list: () => [...entries.values()].map((e) => ({ ...e })),
    // The entries that are rows of +turnId+ (of_turn).
    forTurn: (turnId) => [...entries.values()].filter((e) => turnId != null && e.of_turn === turnId).map((e) => ({ ...e })),
    size: () => entries.size,
    // The running turn's id (null: none running, or it has no id).
    turn: () => (running ? turn : null),
  };
}

// +handlers+ (the stream's, app.js) with the card events wrapped: the
// page's handler first, then the registry's apply (a throw in apply never
// reaches the page). Like participant_main.js wrapHandlers. With the perf
// probe on (stage_probe.js), each apply is timed ("cards:apply") and the
// page gets globalThis.chiCardRegistry: its size and its entries' JSON bytes.
export function observeCards(registry, handlers) {
  if (!registry) return handlers;
  if (probing()) globalThis.chiCardRegistry = { size: () => registry.size(), bytes: () => JSON.stringify(registry.list()).length };
  const wrapped = { ...handlers };
  for (const type of CARD_EVENTS) {
    const original = handlers[type];
    wrapped[type] = (data) => {
      const out = original?.(data);
      try {
        measured("cards:apply", () => registry.apply(type, data));
      } catch (_) { /* an observer never breaks the page */ }
      return out;
    };
  }
  return wrapped;
}
