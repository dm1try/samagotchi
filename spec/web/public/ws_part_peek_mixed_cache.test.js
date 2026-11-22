// A mixed cache around the prompt peek (docs/internals/web-frontend.md, New
// exports go in new modules): a proxy that ignores no-cache may serve
// 0.183.0's ws_reader.js and ws_peek.js beside this working_set_view.js,
// 0.183.0's view beside this ws_reader.js, or 0.183.0's ws_sections.js
// (start rows without partKeys) beside both. Each set is loaded from a copy
// of the page's modules with the old files put back (fixtures/v0.183.0/, the
// released files). The new view without a part peek, or with rows without
// their parts' keys, draws today's rows (no ▸ on a part, 520 wide); the old
// view ignores the new peek's part and still finds PEEK_WIDTH. Goes at the next release, with PEEK_WIDTH (kept
// for an older cached view in ws_peek.js). Build 2's stale states: chi web's GET's parts reach the start rows
// through ws_sections.js (an option, no new export); 0.183.0's ws_sections.js and stream_handlers.js beside
// this view say no stale and throw nothing; with this page's modules an event (no parts) keeps the GET's states.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(here, "../../../lib/samagotchi/web/public");
const OLD = join(here, "fixtures/v0.183.0");
if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

// The page's modules with +oldFiles+ as 0.183.0 shipped them; their view, reader and working_set.js.
async function mixedPage(oldFiles) {
  const dir = mkdtempSync(join(tmpdir(), "chi-mixed-ws-"));
  test.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(PUBLIC, dir, { recursive: true });
  for (const file of oldFiles) cpSync(join(OLD, file), join(dir, file));
  const url = (file) => pathToFileURL(join(dir, file)).href;
  return Promise.all([import(url("working_set_view.js")), import(url("ws_reader.js")), import(url("working_set.js")), import(url("stream_handlers.js"))]);
}

const PARTS = [
  { kind: "tools", label: "2 declared", chars: 400, tokens: 100 },
  { kind: "base", label: "base prompt", chars: 8400, tokens: 2100 },
  { kind: "identity", label: "identity", chars: 2400, tokens: 600, ref: "identity", scope: "system" },
];

// +states+: the GET's parts (none: no GET asked).
function open([{ createWorkingSet }, { createWorkingSetPreview }, { itemsOfTurn }], session, { states = null } = {}) {
  const center = document.createElement("section");
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(center, historyEl, infoEl);
  const getItem = (_id, kind, key) => Promise.resolve({ kind, key, events: [] });
  const preview = createWorkingSetPreview({ centerEl: center, session: () => session, state: () => ({ dir: "/p" }), getItem, getPart: () => Promise.resolve({}) });
  const current = { preloadedMemories: [], mutedMemories: [], usedMemories: [], dir: "/p", promptParts: PARTS, ctxTokens: 9000, ctxWindow: 128000 };
  const getWorkingSet = states ? () => Promise.resolve({ items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }], at: 2, running: false, parts: states }) : undefined;
  const ws = createWorkingSet({ historyEl, infoEl, state: () => current, session: () => session, peek: preview.peek, onTimeline: preview.open, getWorkingSet });
  preview.attach(ws);
  const read = { tool: "read", title: "a.rb", status: "ok", tool_id: "t1", ref: { kind: "file", path: "/p/a.rb" } };
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [read] }] }, 0), prompt: "go" }]);
  ws.update({ items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }], at: 2 });
  ws.popover.open(infoEl.querySelector(".ws-chip"));
  const pop = ws.popover.pop;
  pop.querySelector(".ws-sec.start .ws-sec-head").click();
  const cleanup = () => { ws.popover.close(); center.remove(); historyEl.remove(); infoEl.remove(); pop.remove(); window.localStorage.removeItem(`chi_ws_sections_folded:${session}`); };
  return { pop, ws, cleanup };
}

test("this view with 0.183.0's ws_reader.js and ws_peek.js: no part peek, today's start rows, one width", async () => {
  const v = open(await mixedPage(["ws_reader.js", "ws_peek.js"]), "m1");
  try {
    const start = v.pop.querySelector(".ws-sec.start");
    assert.equal(start.querySelectorAll(".ws-row.part").length, 2);
    assert.equal(start.querySelectorAll(".ws-row.part .ws-peek-toggle").length, 0, "a part row stays read-only");
    const closed = v.pop.style.width;
    v.pop.querySelector('.ws-sec.read .ws-row[data-ws-id="file:/p/a.rb"] .ws-peek-toggle').click();
    await new Promise((r) => setTimeout(r, 0));
    assert.ok(v.pop.querySelector(".ws-peek"));
    assert.equal(v.pop.style.width, closed, "520 open and closed");
  } finally { v.cleanup(); }
});

test("0.183.0's view with this ws_reader.js: the new peek's part ignored, PEEK_WIDTH still there", async () => {
  const v = open(await mixedPage(["working_set_view.js"]), "m2");
  try {
    const start = v.pop.querySelector(".ws-sec.start");
    assert.equal(start.querySelectorAll(".ws-row.part .ws-peek-toggle").length, 0);
    v.pop.querySelector('.ws-sec.read .ws-row[data-ws-id="file:/p/a.rb"] .ws-peek-toggle').click();
    await new Promise((r) => setTimeout(r, 0));
    assert.ok(v.pop.querySelector(".ws-peek"));
  } finally { v.cleanup(); }
});

test("this view and ws_reader.js with 0.183.0's ws_sections.js: start rows without partKeys get no prompt ▸", async () => {
  const v = open(await mixedPage(["ws_sections.js"]), "m3");
  try {
    const start = v.pop.querySelector(".ws-sec.start");
    assert.equal(start.querySelectorAll(".ws-row.part").length, 2);
    assert.equal(start.querySelectorAll(".ws-peek-toggle").length, 0, "no toggle that would load forever");
  } finally { v.cleanup(); }
});

// The event's handler as the page makes it, every other dependency a no-op.
const handlersOf = ({ createStreamHandlers }, workingSet) => createStreamHandlers(new Proxy({ workingSet }, {
  get: (deps, key) => (key in deps ? deps[key] : () => {}),
}));

test("this view with 0.183.0's ws_sections.js and stream_handlers.js: a GET's stale parts show no stale, nothing throws", async () => {
  const modules = await mixedPage(["ws_sections.js", "stream_handlers.js"]);
  const v = open(modules, "m4", { states: [{ key: "identity:identity@system", state: "stale" }] });
  try {
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(v.pop.querySelectorAll(".ws-pstale").length, 0);
    assert.doesNotThrow(() => handlersOf(modules[3], v.ws).working_set_updated({ items: [], at: 3 }));
    assert.equal(v.pop.querySelectorAll(".ws-pstale").length, 0);
  } finally { v.cleanup(); }
});

test("this page's modules: the GET's stale parts show stale; an event through the handler (no parts) keeps them", async () => {
  const modules = await mixedPage([]);
  const v = open(modules, "m5", { states: [{ key: "identity:identity@system", state: "stale" }] });
  try {
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(v.pop.querySelectorAll(".ws-pstale").length, 1);
    handlersOf(modules[3], v.ws).working_set_updated({ items: [], at: 3 });
    assert.equal(v.pop.querySelectorAll(".ws-pstale").length, 1);
  } finally { v.cleanup(); }
});

// chi's own change (by_chi beside state "stale", the own-writes build): an older module never sees "edited".
const OWN = [{ key: "identity:identity@system", state: "stale", by_chi: { tool_id: "t1", step: 1, op: "memory_write", current: true } }];

test("0.183.0's view with a by_chi answer: nothing throws, no stale, no edited row", async () => {
  const v = open(await mixedPage(["working_set_view.js"]), "m6", { states: OWN });
  try {
    await new Promise((r) => setTimeout(r, 0));
    // The start rows were drawn (the absence below is not an empty list's).
    assert.equal(v.pop.querySelectorAll(".ws-sec.start .ws-row.part").length, 2);
    assert.match(v.pop.querySelector(".ws-sec.start").textContent, /identity/);
    assert.equal(v.pop.querySelectorAll(".ws-pstale, .ws-pedited").length, 0);
  } finally { v.cleanup(); }
});

test("this view with 0.183.0's ws_sections.js and a by_chi answer: no partKeys, no edited row, nothing throws", async () => {
  const v = open(await mixedPage(["ws_sections.js"]), "m7", { states: OWN });
  try {
    await new Promise((r) => setTimeout(r, 0));
    // The start rows were drawn (the absence below is not an empty list's).
    assert.equal(v.pop.querySelectorAll(".ws-sec.start .ws-row.part").length, 2);
    assert.match(v.pop.querySelector(".ws-sec.start").textContent, /identity/);
    assert.equal(v.pop.querySelectorAll(".ws-pstale, .ws-pedited").length, 0);
  } finally { v.cleanup(); }
});

test("this page's modules with a by_chi answer: the row says edited, not stale", async () => {
  const v = open(await mixedPage([]), "m8", { states: OWN });
  try {
    await new Promise((r) => setTimeout(r, 0));
    assert.equal(v.pop.querySelectorAll(".ws-pstale").length, 0);
    assert.equal(v.pop.querySelector(".ws-pedited")?.textContent, "identity memory · edited");
  } finally { v.cleanup(); }
});
