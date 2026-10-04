import test from "node:test";
import assert from "node:assert/strict";
import {
  confirmText, createTaskStopper, quietFailure, stopTarget, taskCommand,
} from "../../../lib/samagotchi/web/public/task_stop.js";

const ID = "20261004120000-0a1b2c3d";
const waitRow = (status = "running", view = { task_id: ID }) => ({ tool: "task_wait", status, view });

test("stopTarget: only a running task_wait with a task id, on a worker that has the route", () => {
  assert.equal(stopTarget(waitRow(), ["restart", "task_stop"]), ID);
  assert.equal(stopTarget(waitRow("stopped"), ["task_stop"]), null);
  assert.equal(stopTarget(waitRow("running", null), ["task_stop"]), null);
  assert.equal(stopTarget({ ...waitRow(), tool: "task_get" }, ["task_stop"]), null);
  assert.equal(stopTarget(waitRow(), ["restart"]), null);
  assert.equal(stopTarget(waitRow(), undefined), null);
});

test("taskCommand: the command of this turn's task_create that started the task", () => {
  const gens = [{ tools: [
    { tool: "execute", output: `task_id: ${ID}`, view: { command: "no" } },
    { tool: "task_create", output: "[task_create]\ntask_id: other\nstatus: running", view: { command: "other" } },
    { tool: "task_create", output: `task_id: ${ID}\nstatus: running`, view: { command: "npm run build" } },
  ] }];
  assert.equal(taskCommand(gens, ID), "npm run build");
  assert.equal(taskCommand(gens, "missing"), null);
  assert.equal(taskCommand(undefined, ID), null);
});

test("confirmText: the command on one line, cut, else the id", () => {
  assert.equal(confirmText(ID, "for i in 1 2;\n  do echo $i; done"), "Stop task for i in 1 2; do echo $i; done?");
  assert.equal(confirmText(ID, null), `Stop task ${ID}?`);
  assert.equal(confirmText(ID, "x".repeat(200)).length, "Stop task ?".length + 120);
});

test("quietFailure: 409 and 503 only", () => {
  assert.equal(quietFailure({ status: 409 }), true);
  assert.equal(quietFailure({ status: 503 }), true);
  assert.equal(quietFailure({ status: 502 }), false);
  assert.equal(quietFailure(undefined), false);
});

function stopper(overrides = {}) {
  const calls = [];
  const alerts = [];
  const s = createTaskStopper({
    sessionId: () => "s1",
    features: () => ["task_stop"],
    stopTask: (id, taskId) => { calls.push([id, taskId]); return Promise.resolve({ status: "stopped" }); },
    confirm: () => true,
    alert: (text) => alerts.push(text),
    ...overrides,
  });
  return { s, calls, alerts };
}

test("a confirmed stop posts once and stays in flight; a second click does nothing", async () => {
  const { s, calls } = stopper();
  assert.equal(s.target(waitRow()), ID);
  const first = s.stop(ID, "sleep 9");
  assert.equal(s.busy(ID), true);
  assert.equal(await s.stop(ID), false);
  assert.equal(await first, true);
  assert.equal(s.busy(ID), true);
  assert.deepEqual(calls, [["s1", ID]]);
});

test("a declined confirm posts nothing", async () => {
  const { s, calls } = stopper({ confirm: () => false });
  assert.equal(await s.stop(ID), false);
  assert.equal(s.busy(ID), false);
  assert.deepEqual(calls, []);
});

test("a failed stop frees the button; 409/503 quietly, anything else alerts", async () => {
  const fail = (status) => () => Promise.reject(Object.assign(new Error(`boom (${status})`), { status }));
  for (const [status, said] of [[409, []], [503, []], [502, ["boom (502)"]]]) {
    const { s, alerts } = stopper({ stopTask: fail(status) });
    assert.equal(await s.stop(ID), false);
    assert.equal(s.busy(ID), false);
    assert.deepEqual(alerts, said);
  }
});
