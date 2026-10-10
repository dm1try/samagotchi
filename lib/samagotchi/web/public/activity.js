// Pure model for the per-turn tool/memory "activity" panel.
//
// This module has NO DOM dependencies: it maintains a plain-object state
// (rows keyed by iteration:call_index, each with a status + params + output).
// app.js owns the rendering and calls into these functions to transition row
// state from :tool_call_started / :tool_call_completed events. Keeping the
// state pure makes it unit-testable under `node --test` like data.js/format.js.

export const ROW_STATUS = Object.freeze({
  RUNNING: "running",
  OK: "ok",
  ERROR: "error",
  // A call the user's Stop cut: a task_wait (the task itself runs on), a
  // killed or never-started command. Not a failure.
  STOPPED: "stopped",
  // A call a guardrail denied (a hook, the guardrails bundle, a parent's
  // or the user's Deny): it never ran, and it isn't a failed call either.
  BLOCKED: "blocked",
});

// What a row shows for its tool: a plugin tool's label ("chrome:
// screenshot", from its tool_call_started or saved with its result), else
// the tool's name.
export function toolName(row) {
  return row?.label || row?.tool || "tool";
}

// Create a fresh activity model for one turn.
export function newActivity() {
  return { rows: [] };
}

// Stable key for a call within a turn. iteration + call_index are both present
// on :tool_call_started and :tool_call_completed, so the same key links a
// "running" row to its completion.
export function rowKey(iteration, callIndex) {
  return `${iteration ?? 0}:${callIndex ?? 0}`;
}

// Upsert a row from a :tool_call_started event. Returns { row, created }.
// If a row with the same key already exists (duplicate start), it is reset to
// running and updated rather than duplicated. +now+ (ms): when the page saw
// the call start, for its duration; none for an event a re-render replays
// (`replayed`: the call started before the page looked).
export function addStarted(model, event = {}, now = null) {
  const iteration = event.iteration ?? 0;
  const callIndex = event.call_index ?? 0;
  const key = rowKey(iteration, callIndex);
  let row = model.rows.find((r) => r.key === key);
  if (row) {
    row.status = ROW_STATUS.RUNNING;
    row.tool = event.tool || row.tool;
    row.label = event.label || row.label;
    row.params = event.params || row.params;
    row.title = event.title || row.title;
    row.called_as = event.called_as || row.called_as;
    row.view = event.view || row.view;
    markStart(row, event, now);
    return { row, created: false };
  }
  row = {
    key,
    iteration,
    callIndex,
    tool: event.tool || "tool",
    label: event.label || null,
    params: event.params || "",
    // What the call did in a few words (the server's tool title: a
    // project-relative path, a command without its "cd … &&"); rows show it
    // in place of the params when there is one.
    title: event.title || null,
    // The name the model called the tool by when it was an alias's ("bash"
    // run as execute); the row says so.
    called_as: event.called_as || null,
    // The call's full arguments for the expanded row and the hovers (the
    // server's ToolView: an execute/task_create's command, its cwd).
    view: event.view || null,
    status: ROW_STATUS.RUNNING,
    output: "",
    output_truncated: false,
  };
  markStart(row, event, now);
  model.rows.push(row);
  return { row, created: true };
}

function markStart(row, event, now) {
  if (now !== null && !event.replayed) row.startedAt = now;
  else delete row.startedAt;
}

// Update (or synthesize) a row from a :tool_call_completed event. Returns the row.
// If no matching :tool_call_started was seen (e.g. a replay gap), a row is
// created on the fly so the completion is never lost. Its duration
// (duration_ms, as a reloaded row has it from the tool record): a
// snapshot's own, else from the start the page saw to +now+, less the time
// the call waited for an approval (waited_ms), as the worker times it.
export function addCompleted(model, event = {}, now = null) {
  const iteration = event.iteration ?? 0;
  const callIndex = event.call_index ?? 0;
  const key = rowKey(iteration, callIndex);
  let row = model.rows.find((r) => r.key === key);
  if (!row) {
    const synthesized = addStarted(model, {
      iteration,
      call_index: callIndex,
      tool: event.tool,
      label: event.label,
      params: event.activity?.params || "",
      title: event.activity?.title,
      called_as: event.activity?.called_as,
      view: event.view,
    });
    row = synthesized.row;
  }
  row.status = completedStatus(event.activity?.status);
  row.output = event.output || "";
  row.output_truncated = !!event.output_truncated;
  if (event.activity?.params) row.params = event.activity.params;
  if (event.activity?.title) row.title = event.activity.title;
  if (event.activity?.called_as) row.called_as = event.activity.called_as;
  // A grep that found nothing (status ok): the row says "no match".
  if (event.activity?.no_match) row.no_match = true;
  // The images the tool returned (a reload in the turn view draws them from
  // the saved parts, turn_html.js toolRowHtml).
  if (event.images?.length) row.images = event.images;
  // What an edit/write changed in its file (a reload draws it from the
  // saved parts, turn_html.js toolRowHtml).
  if (event.diff) row.diff = event.diff;
  const duration = callDuration(row, event, now);
  if (duration !== null) row.duration_ms = duration;
  return row;
}

function callDuration(row, event, now) {
  if (event.duration_ms != null) return event.duration_ms;
  if (row.startedAt == null || now === null || event.replayed) return null;
  return Math.max(0, now - row.startedAt - (Number(event.waited_ms) || 0));
}

// A completed call's row status from the server's: error, stopped,
// blocked, else ok.
export function completedStatus(status) {
  if (status === "error") return ROW_STATUS.ERROR;
  if (status === "stopped") return ROW_STATUS.STOPPED;
  if (status === "blocked") return ROW_STATUS.BLOCKED;
  return ROW_STATUS.OK;
}
