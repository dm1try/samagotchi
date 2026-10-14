import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  applyInitEvent, dropDone, fadeDone, initRowTemplate, newInitTasks, seedInitTasks,
} from "../../../lib/samagotchi/web/public/init_row.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

// The row drawn into +row+ (a fresh div by default), as app.js does: its markup.
const initRowHtml = (tasks, row = document.createElement("div")) => {
  render(initRowTemplate(tasks), row);
  return htmlOf(row.cloneNode(true)).replace(/^<div>|<\/div>$/g, "");
};

const started = { bundle: "mcp", id: "mcp-1", label: "Starting MCP server chrome (first run, saving its tools)" };

test("a started task is a running line; done, a ✓ line with its summary that a fade drops", () => {
  const tasks = newInitTasks();
  assert.equal(applyInitEvent(tasks, "plugin_init_started", started), null);
  assert.match(initRowHtml(tasks), /class="init-task running" data-id="mcp-1"><span class="init-spin"[^>]*><\/span><span class="init-bundle">mcp<\/span><span class="init-text">Starting MCP server chrome \(first run, saving its tools\)…<\/span>/);
  const done = applyInitEvent(tasks, "plugin_init_finished", { ...started, ok: true, summary: "chrome ready, 3 tools" });
  assert.equal(done, "mcp-1");
  assert.match(initRowHtml(tasks), /class="init-task done"[^>]*><span class="init-mark"[^>]*>✓<\/span><span class="init-bundle">mcp<\/span><span class="init-text">chrome ready, 3 tools<\/span>/);
  dropDone(tasks, "mcp-1");
  assert.equal(initRowHtml(tasks), "");
});

test("a failed task leaves the row (its warn card says why); a summary-less one says done", () => {
  const tasks = newInitTasks();
  applyInitEvent(tasks, "plugin_init_started", started);
  applyInitEvent(tasks, "plugin_init_started", { bundle: "b", id: "b-1", label: "Indexing" });
  applyInitEvent(tasks, "plugin_init_finished", { ...started, ok: false, error: "gone" });
  applyInitEvent(tasks, "plugin_init_finished", { bundle: "b", id: "b-1", label: "Indexing", ok: true });
  assert.deepEqual([...tasks.keys()], ["b-1"]);
  assert.match(initRowHtml(tasks), /Indexing: done/);
});

test("a snapshot seeds the running tasks and drops done lines; labels are escaped", () => {
  const tasks = newInitTasks();
  applyInitEvent(tasks, "plugin_init_finished", { bundle: "b", id: "b-1", label: "x", ok: true });
  seedInitTasks(tasks, [{ bundle: "p", id: "p-1", label: "<script>" }]);
  assert.deepEqual([...tasks.keys()], ["p-1"]);
  assert.match(initRowHtml(tasks), /&lt;script&gt;…/);
  dropDone(tasks, "p-1");
  assert.deepEqual([...tasks.keys()], ["p-1"]);
  assert.equal(applyInitEvent(tasks, "plugin_init_started", {}), null);
});

test("a fading done line draws faded; a redraw keeps it so, and the line after it keeps its node", () => {
  const tasks = newInitTasks();
  const row = document.createElement("div");
  applyInitEvent(tasks, "plugin_init_started", started);
  applyInitEvent(tasks, "plugin_init_started", { bundle: "b", id: "b-1", label: "Indexing" });
  initRowHtml(tasks, row);
  const second = row.querySelector('[data-id="b-1"]');
  applyInitEvent(tasks, "plugin_init_finished", { ...started, ok: true });
  fadeDone(tasks, "mcp-1");
  fadeDone(tasks, "b-1");
  assert.match(initRowHtml(tasks, row), /class="init-task done fading" data-id="mcp-1"/);
  assert.match(initRowHtml(tasks, row), /class="init-task running" data-id="b-1"/);
  assert.ok(row.querySelector('[data-id="b-1"]') === second);
});

test("a dropped line takes its node with it: the next line keeps its own", () => {
  const tasks = newInitTasks();
  const row = document.createElement("div");
  applyInitEvent(tasks, "plugin_init_finished", { ...started, ok: true });
  applyInitEvent(tasks, "plugin_init_finished", { bundle: "b", id: "b-1", label: "Indexing", ok: true });
  fadeDone(tasks, "mcp-1");
  initRowHtml(tasks, row);
  const faded = row.querySelector('[data-id="mcp-1"]');
  const second = row.querySelector('[data-id="b-1"]');
  dropDone(tasks, "mcp-1");
  assert.match(initRowHtml(tasks, row), /^<div class="init-task done" data-id="b-1">/);
  assert.ok(row.querySelector('[data-id="b-1"]') === second);
  assert.equal(faded.isConnected, false);
});
