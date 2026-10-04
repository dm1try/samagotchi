// The stop-task button on a running task_wait (POST …/tasks/:task_id/stop,
// Bridge#handle_task_stop): the worker kills the task as the user, the wait
// returns, and the turn goes on. Which row gets one, what the confirm says,
// and the stops in flight. The in-flight set lives here, not in the DOM:
// the stage rebuilds its "now" slot, and a redraw must keep a clicked
// button disabled. Pure but for the injected calls, so `node --test`
// covers it; turn_view.js and stage_view.js draw the button.
import { stopTask as postStopTask } from "./data.js";

// What a worker that has the route names in its sidecar features.
export const TASK_STOP_FEATURE = "task_stop";
const COMMAND_SHOWN = 120;

// The task a row's button would stop: a running task_wait's (its server
// view's task_id), on a worker that has the route; else null.
export function stopTarget(row, features) {
  if (!row || row.tool !== "task_wait" || row.status !== "running") return null;
  if (!Array.isArray(features) || !features.includes(TASK_STOP_FEATURE)) return null;
  return row.view?.task_id || null;
}

// The command a task_create of this turn started +taskId+ with (its row's
// view), or null: a task from an earlier turn has no row here.
export function taskCommand(gens, taskId) {
  for (const gen of gens || []) {
    for (const row of gen.tools || []) {
      if (row.tool !== "task_create") continue;
      const id = /(?:^|\n)task_id: (\S+)/.exec(row.output || "")?.[1];
      if (id === taskId) return row.view?.command || null;
    }
  }
  return null;
}

export function confirmText(taskId, command) {
  const line = String(command || "").replace(/\s+/g, " ").trim();
  const what = !line ? taskId : line.length > COMMAND_SHOWN ? `${line.slice(0, COMMAND_SHOWN - 1)}…` : line;
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
  const keyOf = (taskId) => `${sessionId()}|${taskId}`;
  return {
    target: (row) => stopTarget(row, features()),
    busy: (taskId) => inFlight.has(keyOf(taskId)),
    // true once the worker stopped it. A stop that went through stays in
    // flight: the button goes with its row's completion a moment later.
    async stop(taskId, command = null) {
      const id = sessionId();
      const key = keyOf(taskId);
      if (!id || inFlight.has(key) || !confirm(confirmText(taskId, command))) return false;
      inFlight.add(key);
      try {
        await stopTask(id, taskId);
        return true;
      } catch (e) {
        inFlight.delete(key);
        if (!quietFailure(e)) alert(e.message);
        return false;
      }
    },
  };
}

// The button itself (the one DOM part): a click asks, posts, and keeps it
// disabled while the stop is in flight. +command+ is read at the click;
// +onChange+ lets a view redraw (the stage's slot).
export function taskStopButton(stopper, taskId, { command = () => null, onChange = () => {} } = {}) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "ghost task-stop";
  btn.textContent = "stop task";
  btn.title = "Kill this background task; the model is told you stopped it";
  btn.disabled = stopper.busy(taskId);
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
