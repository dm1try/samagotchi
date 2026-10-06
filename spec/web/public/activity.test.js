import test from "node:test";
import assert from "node:assert/strict";
import {
  newActivity,
  rowKey,
  addStarted,
  addCompleted,
} from "../../../lib/samagotchi/web/public/activity.js";

test("newActivity starts empty", () => {
  const m = newActivity();
  assert.deepEqual(m.rows, []);
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
  assert.equal(m.rows.length, 1);
});

test("addStarted with the same key does not duplicate", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "read", params: "a" });
  const { created } = addStarted(m, { iteration: 1, call_index: 1, tool: "read", params: "b" });
  assert.equal(created, false);
  assert.equal(m.rows.length, 1);
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

test("addCompleted marks a task_wait the user's Stop ended as stopped, not ok", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "task_wait", params: "task_id=\"t1\"" });
  const row = addCompleted(m, {
    iteration: 1,
    call_index: 1,
    tool: "task_wait",
    output: "[task_wait]\nwait_result: canceled",
    activity: { action: "waiting for task", status: "stopped", tool: "task_wait" },
  });
  assert.equal(row.status, "stopped");
});

test("addCompleted marks a guardrail-denied call as blocked, not ok", () => {
  const m = newActivity();
  addStarted(m, { iteration: 3, call_index: 1, tool: "execute", params: "echo hi" });
  const row = addCompleted(m, {
    iteration: 3,
    call_index: 1,
    tool: "execute",
    output: "[execute] Error: denied by guardrail (bundle loop-guard): repeated call.",
    activity: { action: "running command", status: "blocked", tool: "execute" },
  });
  assert.equal(row.status, "blocked");
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
  assert.equal(m.rows.length, 1);
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

test("addCompleted keeps an edit's diff on the row", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "edit" });
  const diff = { text: "@@ -1 +1 @@\n-a\n+b", added: 1, removed: 1 };
  assert.deepEqual(addCompleted(m, { iteration: 1, call_index: 1, tool: "edit", output: "Edited", diff }).diff, diff);
  addStarted(m, { iteration: 1, call_index: 2, tool: "execute" });
  assert.equal("diff" in addCompleted(m, { iteration: 1, call_index: 2, tool: "execute", output: "ok" }), false);
});

test("a row keeps its call's view from tool_call_started; a row synthesized from a completion takes the event's", () => {
  const view = { command: "cd /p && rg -n foo lib |\n  head -5", cwd: "lib" };
  const m = newActivity();
  const { row } = addStarted(m, { iteration: 1, call_index: 1, tool: "execute", params: "p", view });
  assert.deepEqual(row.view, view);
  addCompleted(m, { iteration: 1, call_index: 1, tool: "execute", output: "x", activity: { status: "ok" } });
  assert.deepEqual(row.view, view);

  const synthesized = addCompleted(m, { iteration: 2, call_index: 1, tool: "execute", output: "x", view, activity: { status: "ok" } });
  assert.deepEqual(synthesized.view, view);
  assert.equal(addStarted(m, { iteration: 3, call_index: 1, tool: "read", params: "p" }).row.view, null);
});

test("a call's duration: from the start the page saw, less its approval wait; a snapshot's own; none for a replay", () => {
  const m = newActivity();
  addStarted(m, { iteration: 1, call_index: 1, tool: "execute" }, 1000);
  assert.equal(addCompleted(m, { iteration: 1, call_index: 1, waited_ms: 300 }, 1750).duration_ms, 450);
  // A snapshot's completion carries the worker's timing.
  addStarted(m, { iteration: 1, call_index: 2, tool: "read", replayed: true }, 5000);
  assert.equal(addCompleted(m, { iteration: 1, call_index: 2, duration_ms: 1250, replayed: true }, 5000).duration_ms, 1250);
  // A replayed start (an older worker's snapshot, no duration_ms) is no clock.
  addStarted(m, { iteration: 1, call_index: 3, tool: "read", replayed: true }, 5000);
  assert.equal("duration_ms" in addCompleted(m, { iteration: 1, call_index: 3 }, 9000), false);
  // A completion with no start seen, or no clock given: no duration.
  assert.equal("duration_ms" in addCompleted(m, { iteration: 2, call_index: 1, tool: "x" }, 9000), false);
  addStarted(m, { iteration: 3, call_index: 1, tool: "x" });
  assert.equal("duration_ms" in addCompleted(m, { iteration: 3, call_index: 1 }), false);
});
