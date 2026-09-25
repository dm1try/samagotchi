import test from "node:test";
import assert from "node:assert/strict";
import { stripColumns, stripShowParts } from "../../../lib/samagotchi/web/public/strip.js";

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
  assert.deepEqual(stripShowParts([]), { count: "sessions", live: "" });
  assert.deepEqual(stripShowParts(undefined), { count: "sessions", live: "" });
  assert.deepEqual(stripShowParts([{ owner: null }]), { count: "1 session", live: "" });
  assert.deepEqual(stripShowParts([{}, {}, {}, {}, {}]), { count: "5 sessions", live: "" });
});

test("stripShowParts: counts the sessions a worker runs as live, not terminal ones", () => {
  const list = [{ owner: "worker" }, { owner: "tui" }, {}, { owner: "worker" }];
  assert.deepEqual(stripShowParts(list), { count: "4 sessions", live: "2 live" });
  assert.equal(stripShowParts([{ owner: "worker" }]).live, "1 live");
});
