// block_open.js: whether a finished turn's steps block stays open.
import assert from "node:assert/strict";
import { test } from "node:test";
import { openAfterEnd } from "../../../lib/samagotchi/web/public/block_open.js";

test("openAfterEnd: only a turn cut short with an outline stays open", () => {
  for (const [kind, open] of [["completed", false], ["gone", false], ["canceled", true], ["failed", true]]) {
    assert.equal(openAfterEnd(kind, true), open, `${kind}, outlined`);
    assert.equal(openAfterEnd(kind, false), false, `${kind}, nothing outlined`);
  }
});
