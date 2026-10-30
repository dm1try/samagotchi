import test from "node:test";
import assert from "node:assert/strict";
import { createLatest, stillOn } from "../../../lib/samagotchi/web/public/latest.js";

test("stillOn holds while the key is the one asked for", () => {
  let open = "a";
  const still = stillOn(() => open);
  assert.equal(still(), true);
  open = "b";
  assert.equal(still(), false);
  open = "a";
  assert.equal(still(), true);
});

test("stillOn takes the key asked for when it isn't the current one", () => {
  let open = "a";
  const still = stillOn(() => open, "b");
  assert.equal(still(), false);
  open = "b";
  assert.equal(still(), true);
});

test("createLatest: only the newest ask is fresh", () => {
  const latest = createLatest();
  const first = latest.begin();
  assert.equal(first(), true);
  const second = latest.begin();
  assert.equal(first(), false);
  assert.equal(second(), true);
});

test("createLatest: a key change makes the ask stale; drop makes every ask stale", () => {
  let open = "a";
  const latest = createLatest(() => open);
  const ask = latest.begin();
  open = "b";
  assert.equal(ask(), false);
  const next = latest.begin();
  assert.equal(next(), true);
  latest.drop();
  assert.equal(next(), false);
});
