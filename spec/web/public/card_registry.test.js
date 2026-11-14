// The open session's cards as data (card_registry.js): each card event, a
// read's seed, idempotence (an event twice is once; a read seeded then its
// replay applied is the read), and for every stage cut
// (spec/shared/stage_cuts/*.json) the registry that lived through the
// events to the cut equals the one seeded from the cut's show with its
// replay applied (the R3 class: seed against replay order), as a table.
import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { CARD_EVENTS, createCardRegistry, observeCards } from "../../../lib/samagotchi/web/public/card_registry.js";
import { questionWait } from "../../../lib/samagotchi/web/public/card_kinds.js";

const DIR = new URL("../../shared/stage_cuts/", import.meta.url);
const scenarios = readdirSync(DIR).filter((f) => f.endsWith(".json")).sort()
  .map((f) => ({ name: f.replace(/\.json$/, ""), ...JSON.parse(readFileSync(new URL(f, DIR), "utf8")) }));

// A registry's entries by key (the order it heard of them is not the data).
const byKey = (registry) => Object.fromEntries(registry.list().map((e) => [e.key, e]).sort(([a], [b]) => a.localeCompare(b)));

function lived(events, registry = createCardRegistry()) {
  for (const e of events) registry.apply(e.type, e);
  return registry;
}
const seededReplayed = (show) => lived(show.replay || [], createCardRegistry().seed(show));

const PQ = { id: "q1", kind: "question", question: "Which one?", options: ["a", "b"] };
const APPROVAL = {
  id: "a1", kind: "approval", header: "Approve tool call?", question: "execute: echo ok", options: ["Allow once", "Deny"],
  approval: { tool: "execute", command: "echo ok\nmore", cwd: "/work" },
};
const CHECK_IN = { id: "check-in", title: "3 tool calls", level: "info", actions: [{ label: "Nudge", command: "/check-in nudge" }], in_turn: true };

test("a question of the running turn: pending with the turn's id and step, then answered", () => {
  const r = lived([
    { type: "turn_started", turn_id: "T1" },
    { type: "generation_started", iteration: 2 },
    { type: "tool_call_started", iteration: 2, call_index: 3 },
    { type: "question_requested", pending_question: PQ },
  ]);
  assert.deepEqual(r.get("q:q1"), {
    key: "q:q1", kind: "question", status: "pending", of_turn: "T1", opening_id: null, step: { iteration: 2, calls: 3 },
    relayed_to: null, summary: "Which one?",
  });
  r.apply("question_answered", { id: "q1", answer: { selected: ["a"] } });
  assert.equal(r.get("q:q1").status, "answered");
  assert.equal(r.turn(), "T1");
});

test("an approval: its kind and summary as card_kinds.js says; cancelled; relayed to the parent and back", () => {
  const r = lived([{ type: "turn_started", turn_id: "T1" }, { type: "question_requested", pending_question: APPROVAL }]);
  assert.equal(r.get("q:a1").kind, "approval");
  assert.equal(r.get("q:a1").summary, questionWait(APPROVAL).summary);
  r.apply("question_relay", { id: "a1", relayed_to: { session: "p1" } });
  assert.deepEqual(r.get("q:a1").relayed_to, { session: "p1" });
  r.apply("question_relay", { id: "a1", relayed_to: null });
  assert.equal(r.get("q:a1").relayed_to, null);
  r.apply("question_cancelled", { id: "a1", reason: "superseded" });
  assert.equal(r.get("q:a1").status, "cancelled");
});

test("an answer or a cancel for a question the registry never heard of adds nothing", () => {
  const r = lived([{ type: "question_answered", id: "zz" }, { type: "question_cancelled", id: "yy" }, { type: "question_relay", id: "xx", relayed_to: {} }]);
  assert.equal(r.size(), 0);
});

test("plugin cards: one with actions in the turn asks, one without is shown, a warning is kind warn; a redraw merges", () => {
  const r = lived([
    { type: "turn_started", turn_id: "T1" },
    { type: "generation_started", iteration: 1 },
    { type: "card", ...CHECK_IN },
    { type: "card", id: "w", title: "Careful", level: "warn", in_turn: true },
    { type: "card", id: "btw", title: "btw", actions: [{ label: "Go", command: "/go" }], in_turn: false },
  ]);
  assert.deepEqual(r.get("c:check-in"), {
    key: "c:check-in", kind: "asks", status: "asks", of_turn: "T1", opening_id: null, step: { iteration: 1, calls: 0 },
    relayed_to: null, summary: "3 tool calls", actions: [{ label: "Nudge", command: "/check-in nudge" }],
  });
  assert.equal(r.get("c:w").kind, "warn");
  assert.equal(r.get("c:w").status, "shown");
  // Between turns: no turn of its own, no step, and it doesn't ask.
  assert.equal(r.get("c:btw").of_turn, null);
  assert.equal(r.get("c:btw").step, null);
  assert.equal(r.get("c:btw").status, "shown");
  r.apply("card", { ...CHECK_IN, title: "Done", actions: [] });
  assert.equal(r.get("c:check-in").status, "shown");
  assert.equal(r.get("c:check-in").summary, "Done");
  assert.equal(r.get("c:check-in").of_turn, "T1", "whose row it is stays");
});

test("the turn's end cancels its question still pending (the page cancels the card, no event comes); another turn's stays", () => {
  const r = lived([
    { type: "turn_started", turn_id: "T1" },
    { type: "question_requested", pending_question: PQ },
    { type: "turn_canceled" },
  ]);
  assert.equal(r.get("q:q1").status, "cancelled");
  assert.equal(r.turn(), null);
  // The step limit's question comes after its turn: of no turn, still pending at the next turn's end.
  lived([
    { type: "question_requested", pending_question: { id: "c1", kind: "continue", question: "Continue?" } },
    { type: "turn_started", turn_id: "T2" },
    { type: "turn_completed", turn_id: "T2" },
  ], r);
  assert.equal(r.get("q:c1").status, "pending");
  assert.equal(r.get("q:c1").of_turn, null);
});

test("the continue offer: pending, resolved; the step limit's question drops it (it asks the same), in either order", () => {
  const r = lived([{ type: "continue_offered", context: {} }]);
  assert.deepEqual(r.get("continue"), {
    key: "continue", kind: "continue", status: "pending", of_turn: null, opening_id: null, step: null, relayed_to: null, summary: "",
  });
  r.apply("continue_resolved", { decision: "abort" });
  assert.equal(r.get("continue").status, "resolved");
  r.apply("continue_offered", { context: {} });
  assert.equal(r.get("continue").status, "pending", "no id: a new offer after a resolved one is a new card");
  r.apply("question_requested", { pending_question: { id: "c1", kind: "continue", question: "Continue?" } });
  assert.equal(r.get("continue").status, "dropped");
  const other = lived([
    { type: "question_requested", pending_question: { id: "c1", kind: "continue", question: "Continue?" } },
    { type: "continue_offered", context: {} },
  ]);
  assert.equal(other.get("continue").status, "dropped");
});

test("a final status never goes back to pending; of_turn and step keep the first", () => {
  const r = lived([
    { type: "turn_started", turn_id: "T1" },
    { type: "generation_started", iteration: 1 },
    { type: "question_requested", pending_question: PQ },
    { type: "question_answered", id: "q1" },
    { type: "turn_completed", turn_id: "T1" },
    { type: "turn_started", turn_id: "T2" },
    { type: "generation_started", iteration: 5 },
    { type: "question_requested", pending_question: PQ },
  ]);
  assert.equal(r.get("q:q1").status, "answered");
  assert.equal(r.get("q:q1").of_turn, "T1");
  assert.deepEqual(r.get("q:q1").step, { iteration: 1, calls: 0 });
  // A read whose listing has the answer and whose pending question lags.
  const read = createCardRegistry().seed({
    current_turn: { turn_id: "T1" },
    cards: [{ type: "question", pending_question: PQ, answer: { selected: ["a"] }, in_turn: true, of_turn: "T1", current: true }],
    pending_question: { ...PQ, status: "pending" },
  });
  assert.equal(read.get("q:q1").status, "answered");
});

test("seed: a read's questions (answered, cancelled, open, of an ended turn), cards, pending question and continue offer; it replaces", () => {
  const r = createCardRegistry();
  r.apply("card", { id: "old", title: "old" });
  r.seed({
    current_turn: { turn_id: "T2" },
    cards: [
      { type: "question", pending_question: { ...PQ, id: "h1", status: "pending" }, answer: { selected: ["a"] }, in_turn: true, of_turn: "T1", opening_id: "T1", iteration: 1, calls: 1 },
      { type: "question", pending_question: { ...PQ, id: "h2" }, cancelled: true, reason: "no", in_turn: true, of_turn: "T1" },
      { type: "question", pending_question: { ...PQ, id: "h3" }, in_turn: true, of_turn: "T1", current: false },
      { type: "question", pending_question: { ...APPROVAL, status: "pending" }, in_turn: true, of_turn: "T2", current: true, iteration: 2, calls: 1 },
      { type: "card", ...CHECK_IN, of_turn: "T2", current: true, iteration: 1, calls: 0 },
      { type: "hook_notice", line: "a notice" },
    ],
    pending_question: { ...APPROVAL, status: "pending", relayed_to: { session: "p" } },
    continue_offer: { context: {} },
  });
  assert.equal(r.get("c:old"), null);
  assert.deepEqual(Object.fromEntries(r.list().map((e) => [e.key, e.status])), {
    "q:h1": "answered", "q:h2": "cancelled", "q:h3": "cancelled", "q:a1": "pending", "c:check-in": "asks", continue: "pending",
  });
  assert.equal(r.get("q:h1").opening_id, "T1");
  assert.deepEqual(r.get("q:h1").step, { iteration: 1, calls: 1 });
  assert.deepEqual(r.get("q:a1").relayed_to, { session: "p" });
  assert.deepEqual(r.forTurn("T1").map((e) => e.key), ["q:h1", "q:h2", "q:h3"]);
  assert.deepEqual(r.forTurn("T2").map((e) => e.key), ["q:a1", "c:check-in"]);
  assert.equal(r.turn(), "T2");
  r.reset();
  assert.equal(r.size(), 0);
  assert.equal(r.turn(), null);
});

test("an event applied twice is applied once, at every cut", () => {
  for (const s of scenarios) {
    for (const cut of s.cuts) {
      const events = s.events.slice(0, cut.at);
      assert.deepEqual(byKey(lived(events.flatMap((e) => [e, e]))), byKey(lived(events)), `${s.name}/${cut.label}`);
    }
  }
});

test("a read seeded then its replay applied is the read seeded, at every cut", () => {
  for (const s of scenarios) {
    for (const cut of s.cuts) {
      assert.deepEqual(byKey(seededReplayed(cut.show)), byKey(createCardRegistry().seed(cut.show)), `${s.name}/${cut.label}`);
    }
  }
});

// The R3 class (seed against replay order) as a table: what the page that
// lived to the cut holds is what a reload there seeds and replays. All but
// opening_id: a read's place stamp (CardStore's, once the turn's opening is
// in the messages: the turn-end cuts), which no live event carries.
const unstamped = (registry) => Object.fromEntries(Object.entries(byKey(registry)).map(([key, { opening_id: _, ...e }]) => [key, e]));
for (const s of scenarios) {
  for (const cut of s.cuts) {
    test(`${s.name}/${cut.label}: the events to the cut equal the cut's show seeded, its replay applied`, () => {
      const live = lived(s.events.slice(0, cut.at));
      assert.ok(live.size() > 0, "a card at the cut");
      assert.deepEqual(unstamped(seededReplayed(cut.show)), unstamped(live));
    });
  }
}

test("observeCards: the page's handler first, then the registry; its result returned; a throw in apply stays out", () => {
  const order = [];
  const registry = { apply: (type) => { order.push(`apply ${type}`); if (type === "card") throw new Error("boom"); } };
  const handlers = { card: () => { order.push("card"); return 7; }, question_requested: async () => { order.push("question"); }, chunk: () => "untouched" };
  const wrapped = observeCards(registry, handlers);
  assert.equal(wrapped.card({}), 7);
  wrapped.question_requested({});
  assert.deepEqual(order, ["card", "apply card", "question", "apply question_requested"]);
  assert.equal(wrapped.chunk, handlers.chunk, "other events as they were");
  // An event the page has no handler for still reaches the registry.
  wrapped.continue_resolved({});
  assert.equal(order.at(-1), "apply continue_resolved");
  assert.ok(CARD_EVENTS.every((type) => typeof wrapped[type] === "function"));
  assert.equal(observeCards(null, handlers), handlers);
});
