import test from "node:test";
import assert from "node:assert/strict";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

test("starts every field empty", () => {
  const s = emptySessionState();
  assert.equal(s.parentId, null);
  assert.equal(s.continues, null);
  assert.equal(s.owner, null);
  assert.equal(s.ctxPct, null);
  assert.equal(s.ctxWindow, null);
  assert.equal(s.ctxWindowSource, null);
  assert.equal(s.llmContext, null);
  assert.equal(s.served, null);
  assert.equal(s.status, "");
  assert.equal(s.model, "");
  assert.equal(s.dir, "");
  assert.equal(s.firstPreview, "");
  assert.deepEqual(s.commands, []);
  assert.deepEqual(s.usedMemories, []);
  assert.deepEqual(s.preloadedMemories, []);
  assert.deepEqual(s.mutedMemories, []);
  assert.deepEqual(s.timing, normalizeTiming());
});

test("each call is a fresh object: one session's writes never reach the next", () => {
  const a = emptySessionState();
  a.parentId = "parent-1";
  a.commands.push({ name: "/x" });
  a.usedMemories.push("m");
  a.timing.turnRecords.push({});
  const b = emptySessionState();
  assert.equal(b.parentId, null);
  assert.deepEqual(b.commands, []);
  assert.deepEqual(b.usedMemories, []);
  assert.deepEqual(b.timing.turnRecords, []);
});
