import test from "node:test";
import assert from "node:assert/strict";
import {
  newActivity,
  rowKey,
  addStarted,
  addCompleted,
  finalizeActivity,
  activityCount,
} from "../../../lib/samagotchi/web/public/activity.js";

test("newActivity starts empty and not finalized", () => {
  const m = newActivity();
  assert.equal(m.finalized, false);
  assert.deepEqual(m.rows, []);
  assert.equal(activityCount(m), 0);
});

test("rowKey is stable per iteration:call_index", () => {
  assert.equal(rowKey(2, 1), "2:1");
  assert.equal(rowKey(undefined, undefined), "0:0");
});

test("addStarted creates a running row", () => {
  const m = newActivity();
  const { row, created } = addStarted(m, {
    iteration: 1,
    call_index: 1,
    tool: "read",
    params: 'path="lib/x.rb"',
  });
  assert.equal(created, true);
  assert.equal(row.status, "running");
  assert.equal(row.tool, "read");
  assert.equal(row.params, 'path="lib/x.rb"');
  assert.equal(row.output, "");
  assert.equal(activityCount(m), 1);
});

test("addStarted with the same key does not duplicate", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "read", params: "a" });
  const { created } = addStarted(m, { iteration: 1, call_index: 1, tool: "read", params: "b" });
  assert.equal(created, false);
  assert.equal(activityCount(m), 1);
  assert.equal(m.rows[0].params, "b");
});

test("addCompleted transitions running -> ok and stores output", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "read", params: 'path="x"' });
  const row = addCompleted(m, {
    iteration: 1,
    call_index: 1,
    tool: "read",
    output: "[read]\nfile contents here",
    output_truncated: false,
    activity: { action: "reading file", status: "ok", params: 'path="x"', tool: "read" },
  });
  assert.equal(row.status, "ok");
  assert.equal(row.output, "[read]\nfile contents here");
  assert.equal(row.output_truncated, false);
});

test("addCompleted marks error when activity.status is error", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "execute", params: "command=\"ls\"" });
  const row = addCompleted(m, {
    iteration: 1,
    call_index: 1,
    tool: "execute",
    output: "[execute] Error: boom",
    output_truncated: false,
    activity: { action: "running command", status: "error", tool: "execute" },
  });
  assert.equal(row.status, "error");
});

test("addCompleted synthesizes a row when no start was seen (replay gap)", () => {
  const m = newActivity();
  const row = addCompleted(m, {
    iteration: 3,
    call_index: 2,
    tool: "memory_read",
    output: "[memory_read]\nbody",
    activity: { action: "reading memory", status: "ok", params: "name=foo", tool: "memory_read" },
  });
  assert.equal(row.status, "ok");
  assert.equal(row.tool, "memory_read");
  assert.equal(activityCount(m), 1);
});

test("rows are ordered by arrival (call_index order)", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "read" });
  addStarted(m, { iteration: 1, call_index: 2, tool: "write" });
  addStarted(m, { iteration: 1, call_index: 3, tool: "memory_read" });
  assert.deepEqual(m.rows.map((r) => r.tool), ["read", "write", "memory_read"]);
  assert.deepEqual(
    m.rows.map((r) => r.key),
    ["1:1", "1:2", "1:3"],
  );
});

test("finalizeActivity marks finalized but keeps rows", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "read" });
  finalizeActivity(m);
  assert.equal(m.finalized, true);
  assert.equal(activityCount(m), 1);
});

test("output_truncated flag is preserved", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "execute" });
  const row = addCompleted(m, {
    iteration: 1,
    call_index: 1,
    tool: "execute",
    output: "[execute]\nbig",
    output_truncated: true,
    activity: { status: "ok" },
  });
  assert.equal(row.output_truncated, true);
});
