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
});

// What a row shows for its tool: a plugin tool's label ("chrome:
// screenshot", from its tool_call_started or saved with its result), else
// the tool's name.
export function toolName(row) {
  return row?.label || row?.tool || "tool";
}

// Create a fresh activity model for one turn.
export function newActivity() {
  return { finalized: false, rows: [] };
}

// Stable key for a call within a turn. iteration + call_index are both present
// on :tool_call_started and :tool_call_completed, so the same key links a
// "running" row to its completion.
export function rowKey(iteration, callIndex) {
  return `${iteration ?? 0}:${callIndex ?? 0}`;
}

// Upsert a row from a :tool_call_started event. Returns { row, created }.
// If a row with the same key already exists (duplicate start), it is reset to
// running and updated rather than duplicated.
export function addStarted(model, event = {}) {
  const iteration = event.iteration ?? 0;
  const callIndex = event.call_index ?? 0;
  const key = rowKey(iteration, callIndex);
  let row = model.rows.find((r) => r.key === key);
  if (row) {
    row.status = ROW_STATUS.RUNNING;
    row.tool = event.tool || row.tool;
    row.label = event.label || row.label;
    row.params = event.params || row.params;
    return { row, created: false };
  }
  row = {
    key,
    iteration,
    callIndex,
    tool: event.tool || "tool",
    label: event.label || null,
    params: event.params || "",
    status: ROW_STATUS.RUNNING,
    output: "",
    output_truncated: false,
  };
  model.rows.push(row);
  return { row, created: true };
}

// Update (or synthesize) a row from a :tool_call_completed event. Returns the row.
// If no matching :tool_call_started was seen (e.g. a replay gap), a row is
// created on the fly so the completion is never lost.
export function addCompleted(model, event = {}) {
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
    });
    row = synthesized.row;
  }
  row.status = event.activity?.status === "error" ? ROW_STATUS.ERROR : ROW_STATUS.OK;
  row.output = event.output || "";
  row.output_truncated = !!event.output_truncated;
  if (event.activity?.params) row.params = event.activity.params;
  // The images the tool returned (a reload in the turn view draws them from
  // the saved parts, turn_view.js reloadRowHtml).
  if (event.images?.length) row.images = event.images;
  return row;
}

// Mark a turn's activity model as finalized (rows stay; rendering collapses).
export function finalizeActivity(model) {
  if (model) model.finalized = true;
  return model;
}

export function activityCount(model) {
  return model ? model.rows.length : 0;
}
