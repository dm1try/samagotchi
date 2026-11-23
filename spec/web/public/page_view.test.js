// The page view (page_view.js) over a stand-in api: what each state draws
// (a page as stored, never ran, a failed run keeping its result, the script
// changed, no such page), Refresh and its answers, Delete asked once, and
// an answer for a page no longer open dropped.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createPageView } from "../../../lib/samagotchi/web/public/page_view.js";

const NOW = Date.parse("2026-11-23T12:00:00Z");
const ago = (minutes) => new Date(NOW - minutes * 60_000).toISOString();
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function page(fields = {}) {
  return {
    name: "usage", title: "Usage, last 7 days", state: "ok", ran_at: ago(2), duration_ms: 812, changed: false,
    changed_after_failure: false, script_changed_at: ago(60), error: null,
    blocks: [{ type: "text", text: "Stored cost\nper model." }], ...fields,
  };
}

function apiError(code, message, status) {
  return Object.assign(new Error(message), { code, status });
}

function harness(answers = {}, { phone = false } = {}) {
  const root = document.createElement("section");
  document.body.replaceChildren(root);
  const calls = [];
  const toasts = [];
  const events = [];
  const pending = new Map();
  let narrow = phone;
  let mediaChange;
  const api = (path, opts = {}) => {
    const key = `${opts.method || "GET"} ${path}`;
    calls.push(key);
    const answer = answers[key];
    if (answer === "hold") return new Promise((resolve, reject) => pending.set(key, { resolve, reject }));
    if (answer instanceof Error) return Promise.reject(answer);
    return Promise.resolve(typeof answer === "function" ? answer() : answer);
  };
  const view = createPageView({
    root, api, toast: (text) => toasts.push(text), copyText: async (text) => { events.push(["copy", text]); return true; },
    back: () => events.push(["back"]), gone: () => events.push(["gone"]), now: () => NOW,
    phone: () => narrow,
    win: { matchMedia: () => ({ addEventListener: (_name, fn) => { mediaChange = fn; } }) }, doc: document,
  });
  const $ = (sel) => root.querySelector(sel);
  const text = (sel) => $(sel)?.textContent.replace(/\s+/g, " ").trim() ?? null;
  return {
    root, view, calls, toasts, events, pending, $, text,
    setPhone: (value) => { narrow = value; mediaChange(); },
  };
}

test("opening draws the stored page at once: Back, the title, when it ran, Refresh, ⋯, the blocks", async () => {
  const h = harness({ "GET /api/pages/usage": page() });
  h.view.open("usage");
  assert.equal(h.text(".pg-note"), "Loading…");
  await tick();
  assert.deepEqual(h.calls, ["GET /api/pages/usage"]);
  assert.equal(h.text(".pg-back"), "← Sessions");
  assert.equal(h.text(".pg-title"), "Usage, last 7 days");
  assert.equal(h.text(".pg-meta"), "ran 2 min ago · 0.8 s");
  assert.equal(h.text(".pg-refresh"), "Refresh");
  assert.ok(h.$(".pg-menu-btn"));
  // Plain text, its line break kept (no Markdown html in the answer).
  assert.equal(h.$(".pg-text.pg-plain").textContent, "Stored cost\nper model.");
  assert.ok(h.$(".pg-line") === null);
  assert.ok(h.$(".pg-kept") === null);
});

test("what a script wrote is text, never markup; the server's html is the one markup", async () => {
  const h = harness({ "GET /api/pages/x": page({ name: "x", title: "<b>t</b>", blocks: [
    { type: "text", text: "<img src=x onerror=alert(1)>" },
    { type: "text", text: "**a**", html: "<p><strong>a</strong></p>" },
    { type: "future", rows: [] },
  ] }) });
  h.view.open("x");
  await tick();
  assert.equal(h.text(".pg-title"), "<b>t</b>");
  assert.ok(h.root.querySelector("img") === null);
  assert.equal(h.$(".pg-plain").textContent, "<img src=x onerror=alert(1)>");
  assert.equal(h.$(".pg-text.markdown strong").textContent, "a");
  assert.equal(h.text(".pg-unknown"), "A future block this chi web doesn't draw.");
});

test("a failed run keeps the last result, dimmed, under the line naming the script's line; Copy the error", async () => {
  const failed = page({ state: "failed", ran_at: "2026-11-21T14:02:00", error: { message: "undefined method 'fetch' for nil", line: 9, at: ago(1) } });
  const h = harness({ "GET /api/pages/usage": failed });
  h.view.open("usage");
  await tick();
  assert.ok(h.$(".pg-meta") === null);
  assert.match(h.text(".pg-failed"), /^The script failed at line 9: undefined method 'fetch' for nil\. Showing the result from 21 Nov, 14:02\. Copy the error$/);
  assert.equal(h.$(".pg-failed code").textContent, "undefined method 'fetch' for nil");
  assert.ok(h.$(".pg-blocks.pg-kept"));
  h.$(".pg-copy").click();
  await tick();
  assert.deepEqual(h.events, [["copy", "line 9: undefined method 'fetch' for nil"]]);
  assert.deepEqual(h.toasts, ["Copied the error"]);
});

test("a first run that failed: the line alone and no result yet", async () => {
  const h = harness({ "GET /api/pages/usage": page({ state: "failed", ran_at: null, blocks: [], error: { message: "boom", line: 2, at: ago(1) } }) });
  h.view.open("usage");
  await tick();
  assert.match(h.text(".pg-failed"), /^The script failed at line 2: boom\. Copy the error$/);
  assert.equal(h.text(".pg-note"), "No result yet.");
});

test("never ran: no result yet, and Refresh", async () => {
  const h = harness({ "GET /api/pages/usage": page({ state: "never_ran", ran_at: null, blocks: [], duration_ms: null }) });
  h.view.open("usage");
  await tick();
  assert.equal(h.text(".pg-meta"), "never ran");
  assert.equal(h.text(".pg-note"), "No result yet: Refresh runs the script.");
  assert.ok(h.$(".pg-refresh"));
});

test("the script changed since the result: a line says so, and nothing ran", async () => {
  const h = harness({ "GET /api/pages/usage": page({ ran_at: ago(180), changed: true, script_changed_at: ago(12) }) });
  h.view.open("usage");
  await tick();
  assert.equal(h.text(".pg-changed"), "The script changed 12 min ago. This is the result of the earlier version; Refresh runs the new one.");
  assert.deepEqual(h.calls, ["GET /api/pages/usage"]);
});

test("no such page: says so, with Back and no Refresh", async () => {
  const h = harness({ "GET /api/pages/nope": apiError("page_missing", "no page nope", 404) });
  h.view.open("nope");
  await tick();
  assert.equal(h.text(".pg-note"), "There is no page called nope.");
  assert.ok(h.$(".pg-back"));
  assert.ok(h.$(".pg-refresh") === null);
});

test("invalid page names show the missing state without fetching", () => {
  const h = harness();
  for (const name of ["..", ".", "A b"]) {
    const calls = h.calls.length;
    h.view.open(name);
    assert.equal(h.text(".pg-note"), `There is no page called ${name}.`);
    assert.equal(h.calls.length, calls);
  }
});

test("Refresh runs once while it runs, then redraws from the answer, with the script's last words for Copy", async () => {
  const h = harness({ "GET /api/pages/usage": page(), "POST /api/pages/usage/run": "hold" });
  h.view.open("usage");
  await tick();
  h.$(".pg-refresh").click();
  assert.equal(h.text(".pg-refresh"), "Running…");
  assert.equal(h.$(".pg-refresh").disabled, true);
  h.view.refresh(); // a second press is no second run
  assert.deepEqual(h.calls.filter((c) => c.startsWith("POST")), ["POST /api/pages/usage/run"]);
  h.pending.get("POST /api/pages/usage/run").resolve(page({ state: "failed", error: { message: "boom", line: 4, at: ago(0) }, stderr: "last words\n" }));
  await tick();
  assert.equal(h.text(".pg-refresh"), "Refresh");
  assert.ok(h.$(".pg-kept"));
  h.$(".pg-copy").click();
  await tick();
  assert.deepEqual(h.events, [["copy", "line 4: boom\n\nlast words"]]);
});

test("reopening a refreshing page stays running and ignores a GET older than the run answer", async () => {
  let reads = 0;
  let resolveLateRead;
  const h = harness({
    "GET /api/pages/usage": () => {
      reads += 1;
      if (reads < 3) return page({ title: "Stored" });
      return new Promise((resolve) => { resolveLateRead = resolve; });
    },
    "POST /api/pages/usage/run": "hold",
  });
  h.view.open("usage");
  await tick();
  h.$(".pg-refresh").click();

  h.view.close();
  h.view.open("usage");
  await tick();
  assert.equal(h.text(".pg-refresh"), "Running…");
  assert.equal(h.$(".pg-refresh").disabled, true);

  h.view.close();
  h.view.open("usage");
  const fresh = page({ title: "Run answer" });
  h.pending.get("POST /api/pages/usage/run").resolve(fresh);
  await tick();
  assert.equal(h.text(".pg-title"), "Run answer");
  resolveLateRead(page({ title: "Older stored result" }));
  await tick();
  assert.equal(h.text(".pg-title"), "Run answer");
});

test("Refresh clears opened rows and keeps a sort only when that table's columns stay the same", async () => {
  const table = (count) => ({
    type: "table",
    columns: Array.from({ length: count }, (_value, index) => ({
      label: `Column ${index + 1}`, ...(index === 1 ? { key_column: true } : {}),
    })),
    rows: [Array.from({ length: count }, (_value, index) => index === 0 ? "A" : index)],
  });
  for (const [columnCount, expectedSort] of [[4, null], [3, "descending"]]) {
    const h = harness({
      "GET /api/pages/usage": page({ blocks: [table(3)] }),
      "POST /api/pages/usage/run": "hold",
    }, { phone: true });
    h.view.open("usage");
    await tick();
    h.setPhone(false);
    h.$("th:nth-child(2) button").click();
    h.setPhone(true);
    h.$(".pg-row-main").click();
    assert.equal(h.$(".pg-row-main").getAttribute("aria-expanded"), "true");

    h.$(".pg-refresh").click();
    h.pending.get("POST /api/pages/usage/run").resolve(page({ blocks: [table(columnCount)] }));
    await tick();
    assert.equal(h.$(".pg-row-main").getAttribute("aria-expanded"), "false");
    h.setPhone(false);
    assert.equal(h.$("th:nth-child(2)").getAttribute("aria-sort"), expectedSort);
  }
});

test("Refresh's refusals: already running is a toast; a removed page says so and goes back", async () => {
  const busy = harness({ "GET /api/pages/usage": page(), "POST /api/pages/usage/run": apiError("page_busy", "page usage is already running", 409) });
  busy.view.open("usage");
  await tick();
  busy.$(".pg-refresh").click();
  await tick();
  assert.deepEqual(busy.toasts, ["page usage is already running"]);
  assert.equal(busy.text(".pg-refresh"), "Refresh");

  const gone = harness({ "GET /api/pages/usage": page(), "POST /api/pages/usage/run": apiError("page_missing", "no page usage", 404) });
  gone.view.open("usage");
  await tick();
  gone.$(".pg-refresh").click();
  await tick();
  assert.deepEqual(gone.toasts, ["no page usage"]);
  assert.deepEqual(gone.events, [["gone"]]);
});

test("Delete asks once in the menu, then removes the page and leaves", async () => {
  const h = harness({ "GET /api/pages/usage": page(), "DELETE /api/pages/usage": { removed: "usage" } });
  h.view.open("usage");
  await tick();
  h.$(".pg-menu-btn").click();
  assert.equal(h.$(".pg-menu-btn").getAttribute("aria-expanded"), "true");
  h.$(".pg-delete-ask").click();
  assert.equal(h.text(".pg-confirm"), "Delete this page?");
  assert.deepEqual(h.calls, ["GET /api/pages/usage"]);
  h.$(".pg-delete").click();
  await tick();
  assert.deepEqual(h.calls, ["GET /api/pages/usage", "DELETE /api/pages/usage"]);
  assert.deepEqual(h.toasts, ["Deleted the page Usage, last 7 days"]);
  assert.deepEqual(h.events, [["gone"]]);
});

test("an answer for a page no longer open is dropped", async () => {
  const h = harness({ "GET /api/pages/a": "hold", "GET /api/pages/b": page({ name: "b", title: "B" }) });
  h.view.open("a");
  h.view.open("b");
  await tick();
  h.pending.get("GET /api/pages/a").resolve(page({ name: "a", title: "A" }));
  await tick();
  assert.equal(h.text(".pg-title"), "B");

  h.view.close();
  assert.equal(h.root.textContent.trim(), "");
});
