import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorkingSet } from "../../../lib/samagotchi/web/public/working_set_view.js";
import { createWorkingSetPreview } from "../../../lib/samagotchi/web/public/ws_reader.js";
import { partPath } from "../../../lib/samagotchi/web/public/ws_part_peek.js";
import { itemsOfTurn } from "../../../lib/samagotchi/web/public/working_set.js";
import { setTimelineWayIn } from "../../../lib/samagotchi/web/public/ws_way_in.js";

// The prompt peek (ws_part_peek.js): a "From the start" row's ▸ opens what
// chi was sent of that part (the part route), wired as app.js wires the
// reader's peek.
const tick = () => new Promise((r) => setTimeout(r, 0));
// The section folds are session prefs (session_prefs.js reads the global).
if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;
const PARTS = [
  { kind: "tools", label: "2 declared", chars: 400, tokens: 100 },
  { kind: "base", label: "base prompt", chars: 8400, tokens: 2100 },
  { kind: "identity", label: "identity", chars: 2400, tokens: 600, ref: "identity", scope: "system" },
  { kind: "notes", label: "model_notes_y", chars: 3600, tokens: 900, ref: "model_notes_y", scope: "system" },
  { kind: "preloads", label: "model_notes_y", chars: 4800, tokens: 1200, ref: "model_notes_y", scope: "system" },
  { kind: "preloads", label: "style", chars: 400, tokens: 100, ref: "style", scope: "system" },
  { kind: "agents", label: "AGENTS.md", chars: 13600, tokens: 3400, ref: "/p/AGENTS.md" },
];
const ANSWERS = {
  "identity:identity@system": { part: PARTS[2], sent: { lead: "System identity (auto-loaded, scope=system):\n", text: "I am chi." } },
  "tools:2 declared": { part: PARTS[0], tools: [{ name: "execute", chars: 2400 }, { name: "read" }] },
  "notes:model_notes_y@system": { part: PARTS[3], sent: { lead: "## model_notes_y\n", text: "Note text." } },
  "preloads:model_notes_y@system": { part: PARTS[4], sent: { lead: "this memory is required …\n", text: "Preload text." } },
  "preloads:style@system": { part: PARTS[5], sent: { lead: "this memory is required …\n", text: "be brief" } },
  "base:base prompt": { part: PARTS[1], note: "chi builds its prompt at the first turn.", reason: "no_prompt" },
  "agents:/p/AGENTS.md": { part: PARTS[6], note: "chi's prompt changed after it was sent. This is the source now; the sent text shows after the next turn.", changed: "idle", now: { text: "Widgets now.", gone: false } },
};

function page() {
  const center = document.createElement("section");
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(center, historyEl, infoEl);
  const asked = [];
  const getPart = (id, key) => {
    asked.push([id, key]);
    return Promise.resolve(ANSWERS[key] || { part: {}, note: "?" });
  };
  const getItem = (_id, kind, key) => Promise.resolve({ kind, key, events: [{ tool_id: "t5", op: "memory_read", step: 1, sent: true, text: "be brief" }] });
  const preview = createWorkingSetPreview({ centerEl: center, session: () => "s1", state: () => ({ dir: "/p" }), getItem, getPart });
  const current = { preloadedMemories: [], mutedMemories: [], usedMemories: [], dir: "/p", promptParts: PARTS, ctxTokens: 30000, ctxWindow: 128000 };
  const ws = createWorkingSet({ historyEl, infoEl, state: () => current, session: () => "s1", peek: preview.peek, onTimeline: preview.open });
  preview.attach(ws);
  const memoryRow = { tool: "memory_read", title: "style", status: "ok", tool_id: "t5" };
  const fileRow = { tool: "read", title: "a.rb", status: "ok", tool_id: "t1", ref: { kind: "file", path: "/p/a.rb" } };
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [fileRow, memoryRow] }] }, 0), prompt: "go" }]);
  ws.update({ items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }, { kind: "memory", key: "style", scope: "system", state: "live", tokens: 10 }], at: 4 });
  const pop = ws.popover.pop;
  ws.popover.open(infoEl.querySelector(".ws-chip"));
  // From the start opens (folded by default).
  pop.querySelector(".ws-sec.start .ws-sec-head").click();
  const start = () => pop.querySelector(".ws-sec.start");
  const toggleOf = (sel) => start().querySelector(`${sel} .ws-peek-toggle`);
  const cleanup = () => {
    ws.popover.close(); center.remove(); historyEl.remove(); infoEl.remove(); pop.remove(); setTimelineWayIn(false);
    window.localStorage.removeItem("chi_ws_sections_folded:s1");
  };
  return { ws, pop, asked, start, toggleOf, cleanup };
}

test("partPath: the part route with the key encoded whole", () => {
  assert.equal(partPath("s 1", "agents:/p/A B.md"), "/api/sessions/s%201/working_set/part?key=agents%3A%2Fp%2FA%20B.md");
});

test("every From the start row has a ▸; a prompt memory opens as sent: its text, chi's line folded, no foot", async () => {
  const p = page();
  try {
    const rows = [...p.start().querySelectorAll(".ws-row")];
    assert.ok(rows.length >= 6);
    assert.ok(rows.every((r) => r.querySelector(".ws-peek-toggle")), "every row opens");
    p.toggleOf('[data-ws-id="memory:identity"]').click();
    await tick();
    assert.deepEqual(p.asked, [["s1", "identity:identity@system"]]);
    const peek = p.start().querySelector(".ws-part-peek");
    assert.equal(peek.querySelector(".ws-peek-t").textContent, "in the prompt · sent with every request");
    assert.match(peek.querySelector(".wsr-text").textContent, /I am chi\./);
    assert.equal(peek.querySelector(".ws-lead > summary").textContent, "chi adds a line before it");
    assert.equal(peek.querySelector(".ws-lead > pre").textContent, "System identity (auto-loaded, scope=system):\n");
    assert.ok(peek.querySelector(".ws-peek-f") === null, "a prompt peek has no foot buttons");
    assert.equal(p.toggleOf('[data-ws-id="memory:identity"]').getAttribute("aria-expanded"), "true");
    // Closed again.
    p.toggleOf('[data-ws-id="memory:identity"]').click();
    assert.ok(p.start().querySelector(".ws-part-peek") === null);
  } finally { p.cleanup(); }
});

test("tools open as their declared names and sizes; a part row's line when the text isn't there, the source now under it", async () => {
  const p = page();
  try {
    p.toggleOf('.ws-row.part[data-ws-part^="tools"]').click();
    await tick();
    const peek = p.start().querySelector(".ws-part-peek");
    assert.equal(peek.querySelector(".ws-peek-t").textContent, "in the prompt · sent with every request · 2 declared");
    assert.deepEqual([...peek.querySelectorAll(".ws-tool-n")].map((n) => n.textContent), ["execute", "read"]);
    assert.deepEqual([...peek.querySelectorAll(".ws-tool-k")].map((n) => n.textContent), ["~600", ""]);
    p.toggleOf('.ws-row.part[data-ws-part^="base"]').click();
    await tick();
    assert.equal(p.start().querySelectorAll(".ws-part-peek").length, 1, "one open at a time");
    assert.equal(p.start().querySelector(".ws-part-peek .ws-peek-note").textContent, "chi builds its prompt at the first turn.");
    p.toggleOf('.ws-row.part[data-ws-part^="agents"]').click();
    await tick();
    const changed = p.start().querySelector(".ws-part-peek");
    assert.match(changed.querySelector(".ws-peek-note").textContent, /^chi's prompt changed after it was sent/);
    assert.match(changed.querySelector(".wsr-text").textContent, /Widgets now\./);
  } finally { p.cleanup(); }
});

test("one row, several holds: a tab each, kind and size; a read is today's peek and opens first", async () => {
  const p = page();
  try {
    // A note that is also preloaded: one row, two tabs.
    p.toggleOf('[data-ws-id="memory:model_notes_y"]').click();
    await tick();
    let tabs = [...p.start().querySelectorAll(".ws-tab")];
    assert.deepEqual(tabs.map((t) => t.textContent), ["note · ~900", "preload · ~1.2k"]);
    assert.ok(tabs[0].classList.contains("on"));
    assert.match(p.start().querySelector(".ws-part-peek .wsr-text").textContent, /Note text\./);
    tabs[1].click();
    await tick();
    assert.deepEqual(p.asked.map(([, key]) => key), ["notes:model_notes_y@system", "preloads:model_notes_y@system"]);
    assert.match(p.start().querySelector(".ws-part-peek .wsr-text").textContent, /Preload text\./);
    // A prompt memory also read: the read first (the item peek), then the prompt.
    p.toggleOf('[data-ws-id="memory:style"]').click();
    await tick();
    tabs = [...p.start().querySelectorAll(".ws-tab")];
    assert.match(tabs[0].textContent, /^read · /);
    assert.equal(tabs[1].textContent, "preload · ~100");
    assert.ok(p.start().querySelector(".ws-held .ws-peek-open"), "the read's peek, its timeline link");
    tabs[1].click();
    await tick();
    assert.match(p.start().querySelector(".ws-part-peek .wsr-text").textContent, /be brief/);
    assert.ok(p.start().querySelector(".ws-held") === null);
  } finally { p.cleanup(); }
});

test("the popover is one width, closed and with a row open: nothing moves sideways", async () => {
  const p = page();
  try {
    const closed = p.pop.style.width;
    assert.ok(closed);
    p.toggleOf('[data-ws-id="memory:identity"]').click();
    await tick();
    assert.equal(p.pop.style.width, closed);
    // An item peek in Read too.
    p.pop.querySelector('.ws-sec.read .ws-row[data-ws-id="file:/p/a.rb"] .ws-peek-toggle').click();
    await tick();
    assert.equal(p.pop.style.width, closed);
    assert.ok(p.start().querySelector(".ws-part-peek") === null, "the item peek closed the prompt peek");
  } finally { p.cleanup(); }
});
