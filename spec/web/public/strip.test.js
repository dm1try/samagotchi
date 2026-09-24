import test from "node:test";
import assert from "node:assert/strict";
import { stripColumns } from "../../../lib/samagotchi/web/public/strip.js";

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
