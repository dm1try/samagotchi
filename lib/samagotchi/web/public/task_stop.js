// The stop-task button on a running task_wait (POST …/tasks/:task_id/stop,
// Bridge#handle_task_stop): the worker kills the task as the user, the wait
// returns, and the turn goes on. Which row gets one, what the confirm says,
// and the stops in flight. The in-flight set lives here, not in the DOM:
// the stage rebuilds its "now" slot, and a redraw must keep a clicked
// button disabled. Pure but for the injected calls, so `node --test`
// covers it; turn_block.js and stage_view.js draw the button.
import { stopTask as postStopTask } from "./data.js";
import { clip } from "./format.js";

// What a worker that has the route names in its sidecar features.
const TASK_STOP_FEATURE = "task_stop";
const COMMAND_SHOWN = 120;

// The task a row's button would stop: a running task_wait's (its server
// view's task_id), on a worker that has the route; else null.
export function stopTarget(row, features) {
  if (!row || row.tool !== "task_wait" || row.status !== "running") return null;
  if (!Array.isArray(features) || !features.includes(TASK_STOP_FEATURE)) return null;
  return row.view?.task_id || null;
}

// A task_wait row's title without its wait ("npm test · up to 600s").
const WAIT_SUFFIX = / · up to \d+s$/;

// The first line of an execute that was still running at its limit and
// went on as a task (Tools::Execute::HANDED_OVER), then its task_id line.
// Anchored at the start, an optional "ran as: …" line and "[execute]" lead
// before it: a "task_id:" line anywhere else is the command's own output.
// The twin of TaskRuntime.handed_over_id.
const HANDED_OVER = /^(?:ran as: [^\n]*\n)?(?:\[execute\]\n)?Still running at the \d+s limit:[^\n]*\ntask_id: (\S+)/;

// The task id an execute row's output hands over, else null.
export function handedOverId(output) {
  return HANDED_OVER.exec(output || "")?.[1] || null;
}

// The task id a row of this turn started: a task_create's, or an execute's
// hand-over (handedOverId); else null.
function startedId(row) {
  if (row.tool === "execute") return handedOverId(row.output);
  if (row.tool !== "task_create") return null;
  return /(?:^|\n)task_id: (\S+)/.exec(row.output || "")?.[1] || null;
}

// The command a task_create or a handed-over execute of this turn started
// +taskId+ with (its row's view), else a task_wait row's title for it (the
// server titles one by its task's command, also for a task from an earlier
// turn: ToolActivity.task_title), or null.
export function taskCommand(gens, taskId) {
  let titled = null;
  for (const gen of gens || []) {
    for (const row of gen.tools || []) {
      if (row.tool === "task_wait" && row.view?.task_id === taskId && row.title) {
        titled ||= row.title.replace(WAIT_SUFFIX, "");
      }
      if (startedId(row) === taskId) return row.view?.command || null;
    }
  }
  return titled;
}

export function confirmText(taskId, command) {
  const line = String(command || "").replace(/\s+/g, " ").trim();
  const what = line ? clip(line, COMMAND_SHOWN) : taskId;
  return `Stop task ${what}?`;
}

// A failed stop said nothing about: 409 (the task ended meanwhile), 503
// (no live worker: it can't be stopped now).
export function quietFailure(error) {
  return error?.status === 409 || error?.status === 503;
}

// +sessionId+ and +features+ are read at each call (the selected session,
// its worker's sidecar features).
export function createTaskStopper({
  sessionId,
  features,
  stopTask = postStopTask,
  confirm = (text) => globalThis.confirm(text),
  alert = (text) => globalThis.alert(text),
}) {
  const inFlight = new Set();
  const watchers = new Map(); // key -> Set of fn(busy)
  const keyOf = (taskId) => `${sessionId()}|${taskId}`;
  const notify = (key, busy) => watchers.get(key)?.forEach((fn) => fn(busy));
  return {
    target: (row) => stopTarget(row, features()),
    busy: (taskId) => inFlight.has(keyOf(taskId)),
    // Call +fn+ whenever a stop for +taskId+ starts or ends (the key enters
    // or leaves the in-flight set) — the session's own task, on this session.
    // Returns unwatch. A task drawn in two rows (the stage's "now" slot and
    // the step list) so both buttons stay in step; a watcher for a button
    // that is gone unwatches itself.
    watch(taskId, fn) {
      const key = keyOf(taskId);
      let set = watchers.get(key);
      if (!set) watchers.set(key, (set = new Set()));
      set.add(fn);
      return () => set.delete(fn);
    },
    // true once the worker stopped it. A stop that went through stays in
    // flight: the button goes with its row's completion a moment later.
    async stop(taskId, command = null) {
      const id = sessionId();
      const key = keyOf(taskId);
      if (!id || inFlight.has(key) || !confirm(confirmText(taskId, command))) return false;
      inFlight.add(key);
      notify(key, true);
      try {
        await stopTask(id, taskId);
        return true;
      } catch (e) {
        inFlight.delete(key);
        notify(key, false);
        if (!quietFailure(e)) alert(e.message);
        return false;
      }
    },
  };
}

// The button itself (the one DOM part): a click asks, posts, and keeps it
// disabled while the stop is in flight. +command+ is read at the click;
// +onChange+ lets a view redraw (the stage's slot). It also watches the
// task's in-flight state, so a stop started from a second button of the
// same row (the stage draws one in the "now" slot and one in the step
// list) disables this one too — a button that is gone unwatched.
export function taskStopButton(stopper, taskId, { command = () => null, onChange = () => {} } = {}) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "ghost task-stop";
  btn.textContent = "stop task";
  btn.title = "Kill this background task; the model is told you stopped it";
  btn.disabled = stopper.busy(taskId);
  const unwatch = stopper.watch?.(taskId, (busy) => {
    if (!btn.isConnected) { unwatch(); return; }
    btn.disabled = busy;
  });
  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    const pending = stopper.stop(taskId, command());
    btn.disabled = stopper.busy(taskId);
    onChange();
    pending.then(() => {
      btn.disabled = stopper.busy(taskId);
      onChange();
    });
  });
  return btn;
}
