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

// +states+: chi web's GET's parts (the stale ones) when the list opens.
// The part route's &now=1 answers: the sent slice, the source now and its diff.
const NOW_ANSWERS = {
  "agents:/p/AGENTS.md": {
    part: PARTS[6], sent: { lead: "Project specific description:\n", text: "Widgets only." },
    now: { text: "Widgets now.", gone: false, diff: { text: "@@ -1 +1 @@\n-Widgets only.\n+Widgets now.", added: 1, removed: 1, new_file: false } },
  },
  "preloads:style@system": { part: PARTS[5], sent: { lead: "this memory is required …\n", text: "be brief" }, now: { text: null, diff: null, gone: true } },
};

function page({ states = null } = {}) {
  const center = document.createElement("section");
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(center, historyEl, infoEl);
  const asked = [];
  const getPart = (id, key, opts = {}) => {
    asked.push(opts.now ? [id, key, "now"] : [id, key]);
    return Promise.resolve((opts.now ? NOW_ANSWERS[key] : null) || ANSWERS[key] || { part: {}, note: "?" });
  };
  const items = [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }, { kind: "memory", key: "style", scope: "system", state: "live", tokens: 10 }];
  // The GET's states, changed by a test (null: no field).
  const gets = { states };
  const getWorkingSet = states ? () => Promise.resolve({ items, at: 4, running: false, ...(gets.states ? { parts: gets.states } : {}) }) : undefined;
  const getItem = (_id, kind, key) => Promise.resolve({ kind, key, events: [{ tool_id: "t5", op: "memory_read", step: 1, sent: true, text: "be brief" }] });
  const preview = createWorkingSetPreview({ centerEl: center, session: () => "s1", state: () => ({ dir: "/p" }), getItem, getPart });
  const current = { preloadedMemories: [], mutedMemories: [], usedMemories: [], dir: "/p", promptParts: PARTS, ctxTokens: 30000, ctxWindow: 128000 };
  const ws = createWorkingSet({ historyEl, infoEl, state: () => current, session: () => "s1", peek: preview.peek, onTimeline: preview.open, getWorkingSet });
  preview.attach(ws);
  const memoryRow = { tool: "memory_read", title: "style", status: "ok", tool_id: "t5" };
  const fileRow = { tool: "read", title: "a.rb", status: "ok", tool_id: "t1", ref: { kind: "file", path: "/p/a.rb" } };
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [fileRow, memoryRow] }] }, 0), prompt: "go" }]);
  ws.update({ items, at: 4 });
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
  return { ws, pop, asked, start, toggleOf, cleanup, current, gets };
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

test("a stale row (chi web's GET's parts) says stale; its now tab, after its hold, opens first: what changed, as a diff", async () => {
  const p = page({ states: [{ key: "agents:/p/AGENTS.md", state: "stale" }, { key: "preloads:style@system", state: "stale" }] });
  try {
    await tick();
    const agents = p.start().querySelector('.ws-row.part[data-ws-part^="agents"]');
    assert.equal(agents.querySelector(".ws-pstale")?.textContent, "stale");
    assert.equal(p.start().querySelectorAll(".ws-pstale").length, 2, "the stale ones only");
    // In place of the row's words (the mock-up), kept in its title.
    assert.deepEqual([...agents.querySelectorAll(".st")].map((e) => e.textContent), ["stale"]);
    assert.equal(agents.querySelector(".ws-pstale").title, "project instructions · changed after chi's prompt was built");
    const styleSt = [...p.start().querySelectorAll('[data-ws-id="memory:style"] .st')];
    assert.deepEqual(styleSt.map((e) => e.textContent), ["stale"]);
    assert.equal(styleSt[0].title, "preloaded · changed after chi's prompt was built");
    p.toggleOf('.ws-row.part[data-ws-part^="agents"]').click();
    await tick();
    const tabs = [...p.start().querySelectorAll(".ws-tab")];
    assert.deepEqual(tabs.map((t) => t.textContent), ["in the prompt · ~3.4k", "now · changed"]);
    assert.ok(tabs[1].classList.contains("on") && tabs[1].classList.contains("warn"));
    assert.deepEqual(p.asked.at(-1), ["s1", "agents:/p/AGENTS.md", "now"]);
    const peek = p.start().querySelector(".ws-part-peek");
    assert.equal(peek.querySelector(".ws-peek-t").textContent, "AGENTS.md changed after chi's prompt was built");
    assert.equal(peek.querySelector(".ws-peek-c").textContent, "+1 −1");
    assert.match(peek.querySelector(".diff").textContent, /Widgets now\./);
    tabs[0].click();
    await tick();
    assert.deepEqual(p.asked.at(-1), ["s1", "agents:/p/AGENTS.md"], "the prompt's tab asks for the sent slice alone");
    // A held row: the read first, then its preload, its now after it; gone says so.
    p.toggleOf('[data-ws-id="memory:style"]').click();
    await tick();
    const held = [...p.start().querySelectorAll(".ws-tab")];
    assert.deepEqual(held.map((t) => t.textContent.replace(/ · t.*$/, "")), ["read", "preload · ~100", "now · changed"]);
    assert.ok(held[0].classList.contains("on"), "the read opens first");
    held[2].click();
    await tick();
    assert.equal(p.start().querySelector(".ws-part-peek .ws-peek-note").textContent, "Its source is gone now.");
  } finally { p.cleanup(); }
});

test("a read stale and its prompt part stale: one stale word; the now tab names both causes", async () => {
  const p = page({ states: [{ key: "preloads:style@system", state: "stale" }] });
  const saved = NOW_ANSWERS["preloads:style@system"];
  NOW_ANSWERS["preloads:style@system"] = { ...saved, now: { text: "be brief\nand plain", gone: false, diff: { text: "@@ -1 +1,2 @@\n be brief\n+and plain", added: 1, removed: 0, new_file: false } } };
  try {
    await tick();
    p.ws.update({ items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }, { kind: "memory", key: "style", scope: "system", state: "stale", tokens: 10 }], at: 5 });
    await tick();
    const row = p.start().querySelector('.ws-row[data-ws-id="memory:style"]');
    assert.ok(row.classList.contains("stale"), "faded, the read's state");
    assert.deepEqual([...row.querySelectorAll(".st")].map((e) => e.textContent), ["stale"], "never stale stale");
    assert.equal(row.querySelector(".ws-pstale").title, "preloaded · read changed · prompt text changed");
    p.toggleOf('[data-ws-id="memory:style"]').click();
    await tick();
    const now = [...p.start().querySelectorAll(".ws-tab")].find((t) => t.textContent === "now · changed");
    assert.equal(now.title, "read changed · prompt text changed");
    now.click();
    await tick();
    assert.equal(p.start().querySelector(".ws-part-peek .ws-peek-t").textContent, "style: read changed · prompt text changed");
  } finally {
    NOW_ANSWERS["preloads:style@system"] = saved;
    p.cleanup();
  }
});

test("no GET parts: no stale word, no now tab (an event's set carries none)", async () => {
  const p = page();
  try {
    assert.equal(p.start().querySelectorAll(".ws-pstale").length, 0);
    p.toggleOf('.ws-row.part[data-ws-part^="agents"]').click();
    await tick();
    assert.equal(p.start().querySelectorAll(".ws-tab").length, 0);
  } finally { p.cleanup(); }
});

test("an event's set (no parts) keeps the GET's states: stale stays, an open now tab stays on its diff", async () => {
  const p = page({ states: [{ key: "agents:/p/AGENTS.md", state: "stale" }] });
  try {
    await tick();
    p.toggleOf('.ws-row.part[data-ws-part^="agents"]').click();
    await tick();
    assert.ok(p.start().querySelector(".ws-part-peek .diff"));
    p.ws.update({ items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }], at: 5 });
    await tick();
    assert.equal(p.start().querySelectorAll(".ws-pstale").length, 1);
    assert.deepEqual([...p.start().querySelectorAll(".ws-tab")].map((t) => t.textContent), ["in the prompt · ~3.4k", "now · changed"]);
    assert.ok(p.start().querySelector(".ws-part-peek .diff"), "not Loading…");
  } finally { p.cleanup(); }
});

test("a rebuilt prompt asks the GET again: none stale now, the open now tab gives way to the part, never stuck loading", async () => {
  const p = page({ states: [{ key: "agents:/p/AGENTS.md", state: "stale" }] });
  try {
    await tick();
    p.ws.sessionChanged(); // the parts as built so far
    p.toggleOf('.ws-row.part[data-ws-part^="agents"]').click();
    await tick();
    assert.ok(p.start().querySelector(".ws-part-peek .diff"));
    p.gets.states = null;
    p.current.promptParts = PARTS.map((part) => ({ ...part, head: "rebuilt" }));
    p.ws.sessionChanged();
    await tick();
    await tick();
    assert.equal(p.start().querySelectorAll(".ws-pstale").length, 0);
    assert.equal(p.start().querySelectorAll(".ws-tab").length, 0);
    const body = p.start().querySelector(".ws-part-peek").textContent;
    assert.doesNotMatch(body, /Loading…/);
    assert.match(body, /Widgets now\./);
  } finally { p.cleanup(); }
});

test("a now tab whose answer has no source now says so, never the sent text", async () => {
  const p = page({ states: [{ key: "preloads:style@system", state: "stale" }] });
  NOW_ANSWERS["preloads:style@system"] = { part: PARTS[5], sent: { lead: "this memory is required …\n", text: "be brief" } };
  try {
    await tick();
    p.toggleOf('[data-ws-id="memory:style"]').click();
    await tick();
    [...p.start().querySelectorAll(".ws-tab")].find((t) => t.textContent === "now · changed").click();
    await tick();
    const body = p.start().querySelector(".ws-part-peek").textContent;
    assert.match(body, /Couldn't fetch its source now\./);
    assert.doesNotMatch(body, /be brief/);
  } finally {
    NOW_ANSWERS["preloads:style@system"] = { part: PARTS[5], sent: { lead: "this memory is required …\n", text: "be brief" }, now: { text: null, diff: null, gone: true } };
    p.cleanup();
  }
});

test("a GET an event overtook still gives its states (the event's set kept, the GET's parts on it)", async () => {
  const p = page({ states: [{ key: "agents:/p/AGENTS.md", state: "stale" }] });
  try {
    // The list's open asked the GET; an event lands before it answers.
    p.ws.update({ items: [{ kind: "file", key: "/p/a.rb", state: "stale", tokens: 100 }], at: 9 });
    await tick();
    assert.equal(p.start().querySelectorAll(".ws-pstale").length, 1);
    assert.ok(p.pop.querySelector('.ws-sec.read .ws-row.stale[data-ws-id="file:/p/a.rb"]'), "the event's set kept");
  } finally { p.cleanup(); }
});
