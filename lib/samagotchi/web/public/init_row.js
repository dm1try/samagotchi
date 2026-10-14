// Plugins' slow setup (chi.init: an MCP server's first start, a model
// download) as a small row above the composer: a spinner line per running
// task ("mcp · Starting MCP server chrome (first run, saving its tools)…"),
// a "✓ chrome ready, 3 tools" line when one is done, which fades. A failed
// one leaves the row: its warn card says why. The row is a lit-html
// template (initRowTemplate); app.js renders it into #initRow.
import { repeat } from "./vendor/directives/repeat.js";
import { html } from "./vendor/lit-html.js";

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

// A done line's fade starts (DONE_MS after it was done): the line draws
// faded until dropDone takes it.
export function fadeDone(tasks, id) {
  const task = tasks.get(id);
  if (task?.status === "done") task.fading = true;
  return tasks;
}

// Drop a done line (its fade ended); a task started again under the id stays.
export function dropDone(tasks, id) {
  if (tasks.get(id)?.status === "done") tasks.delete(id);
  return tasks;
}

// @returns the row's lines (a lit-html template; none with nothing to show),
// keyed by the task's id: a line keeps its node while the lines around it
// come and go (a faded line's node is never reused for the next one).
export function initRowTemplate(tasks) {
  return repeat(tasks.entries(), ([id]) => id, ([id, t]) => {
    const bundle = html`<span class="init-bundle">${t.bundle}</span>`;
    if (t.status === "done") {
      return html`<div class=${`init-task done${t.fading ? " fading" : ""}`} data-id=${id}><span class="init-mark" aria-hidden="true">✓</span>${bundle}<span class="init-text">${t.summary || `${t.label}: done`}</span></div>`;
    }
    return html`<div class="init-task running" data-id=${id}><span class="init-spin" aria-hidden="true"></span>${bundle}<span class="init-text">${t.label}…</span></div>`;
  });
}
