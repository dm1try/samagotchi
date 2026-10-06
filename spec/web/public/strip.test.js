import test from "node:test";
import assert from "node:assert/strict";
import { SHORT_WINDOW_QUERY, stripAutoHidden, stripColumns, stripShowParts } from "../../../lib/samagotchi/web/public/strip.js";

test("stripColumns: 3 cards up to about 1650 px of strip, then one per 372 px, at most 6", () => {
  assert.equal(stripColumns(600), 3);
  assert.equal(stripColumns(1000), 3);
  assert.equal(stripColumns(1600), 3);
  assert.equal(stripColumns(1650), 4);
  assert.equal(stripColumns(2000), 4);
  assert.equal(stripColumns(2400), 6);
  assert.equal(stripColumns(4000), 6);
});

test("stripColumns: a hidden strip (0 px) or a bad width still gets 3", () => {
  assert.equal(stripColumns(0), 3);
  assert.equal(stripColumns(undefined), 3);
});

test("stripShowParts: the count of the list, singular for one, bare label for none", () => {
  assert.deepEqual(stripShowParts([]), { count: "sessions", live: "", waiting: "" });
  assert.deepEqual(stripShowParts(undefined), { count: "sessions", live: "", waiting: "" });
  assert.deepEqual(stripShowParts([{ owner: null }]), { count: "1 session", live: "", waiting: "" });
  assert.deepEqual(stripShowParts([{}, {}, {}, {}, {}]), { count: "5 sessions", live: "", waiting: "" });
});

test("stripShowParts: counts the sessions a worker runs as live, not terminal ones", () => {
  const list = [{ owner: "worker" }, { owner: "tui" }, {}, { owner: "worker" }];
  assert.deepEqual(stripShowParts(list), { count: "4 sessions", live: "2 live", waiting: "" });
  assert.equal(stripShowParts([{ owner: "worker" }]).live, "1 live");
});

test("stripShowParts: counts the sessions that wait on the user (a question, an approval, a card)", () => {
  const list = [
    { owner: "worker", pending_question: { id: "q1", kind: "question" } },
    { owner: "worker", pending_card: { id: "c1" } },
    { owner: "worker" },
    { pending_question: { id: null } },
  ];
  assert.deepEqual(stripShowParts(list), { count: "4 sessions", live: "3 live", waiting: "2 waiting" });
  assert.equal(stripShowParts([{ pending_card: { id: "c" } }]).waiting, "1 waiting");
});

test("stripShowParts: with cards, the count is the strip's cards (a family is one); live and waiting stay per session", () => {
  const list = [{ owner: "worker" }, { owner: "worker", pending_question: { id: "q" } }, {}];
  assert.deepEqual(stripShowParts(list, { cards: 2 }), { count: "2 sessions", live: "2 live", waiting: "1 waiting" });
  assert.equal(stripShowParts(list, { cards: 1 }).count, "1 session");
});

test("stripAutoHidden: a short window hides the strip until the pill shows it; the user's hide always holds", () => {
  assert.equal(stripAutoHidden({ saved: false, short: false, shownWhileShort: false }), false);
  assert.equal(stripAutoHidden({ saved: false, short: true, shownWhileShort: false }), true);
  assert.equal(stripAutoHidden({ saved: false, short: true, shownWhileShort: true }), false);
  assert.equal(stripAutoHidden({ saved: true, short: false, shownWhileShort: false }), true);
  assert.equal(stripAutoHidden({ saved: true, short: true, shownWhileShort: true }), true);
  assert.match(SHORT_WINDOW_QUERY, /max-height: 700px/);
});
