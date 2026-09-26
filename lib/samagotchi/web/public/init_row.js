// Plugins' slow setup (chi.init: an MCP server's first start, a model
// download) as a small row above the composer: a spinner line per running
// task ("mcp · Starting MCP server chrome (first run, saving its tools)…"),
// a "✓ chrome ready, 3 tools" line when one is done, which fades. A failed
// one leaves the row: its warn card says why. No DOM here, so node --test
// covers it; app.js draws the row.
import { escapeHtml as esc } from "./format.js";

// How long a done line stays before it fades out.
export const DONE_MS = 2500;

// @returns the row's state: task id → { bundle, label, status: running|done, summary }
export function newInitTasks() {
  return new Map();
}

// Replace the state with the tasks a snapshot says still run (a page that
// joins late, a resync); done lines go.
// @param list [{ bundle, id, label }]
export function seedInitTasks(tasks, list) {
  tasks.clear();
  for (const t of list || []) {
    if (t && t.id) tasks.set(t.id, { bundle: t.bundle, label: t.label, status: "running" });
  }
  return tasks;
}

// A plugin_init_started / plugin_init_finished event.
// @returns the id of a task that is now done (for its fade), else null
export function applyInitEvent(tasks, type, data) {
  if (!data || !data.id) return null;
  if (type === "plugin_init_started") {
    tasks.set(data.id, { bundle: data.bundle, label: data.label, status: "running" });
    return null;
  }
  if (type !== "plugin_init_finished") return null;
  if (!data.ok) {
    tasks.delete(data.id);
    return null;
  }
  tasks.set(data.id, { bundle: data.bundle, label: data.label, status: "done", summary: data.summary || null });
  return data.id;
}

// Drop a done line (its fade ended); a task started again under the id stays.
export function dropDone(tasks, id) {
  if (tasks.get(id)?.status === "done") tasks.delete(id);
  return tasks;
}

// @returns the row's inner HTML ("" with nothing to show)
export function initRowHtml(tasks) {
  return [...tasks.entries()].map(([id, t]) => {
    const bundle = `<span class="init-bundle">${esc(t.bundle)}</span>`;
    if (t.status === "done") {
      return `<div class="init-task done" data-id="${esc(id)}"><span class="init-mark" aria-hidden="true">✓</span>${bundle}<span class="init-text">${esc(t.summary || `${t.label}: done`)}</span></div>`;
    }
    return `<div class="init-task running" data-id="${esc(id)}"><span class="init-spin" aria-hidden="true"></span>${bundle}<span class="init-text">${esc(t.label)}…</span></div>`;
  }).join("");
}
