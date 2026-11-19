import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorkingSet } from "../../../lib/samagotchi/web/public/working_set_view.js";
import { createWorkingSetPreview } from "../../../lib/samagotchi/web/public/ws_reader.js";
import { itemsOfTurn, sessionItems } from "../../../lib/samagotchi/web/public/working_set.js";
import { setTimelineWayIn, wayInTemplate } from "../../../lib/samagotchi/web/public/ws_way_in.js";
import { REF_ACTIONS, refActions, refTarget } from "../../../lib/samagotchi/web/public/refs.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

const tick = () => new Promise((r) => setTimeout(r, 0));
const row = (path, id, tool = "read") => ({ tool, title: path, status: "ok", tool_id: id, ref: { kind: "file", path: `/p/${path}` } });
const readEvent = (id, first, last, extra = {}) => ({
  tool_id: id, op: "read", step: 1, sent: true, dropped: false, forgotten: false, lines: { first, last, whole: false, partial: false },
  text: `${Array.from({ length: last - first + 1 }, (_, i) => `line ${first + i}`).join("\n")}\n`, ...extra,
});
const editEvent = (id) => ({ tool_id: id, op: "edit", step: 2, sent: true, diff: { text: "@@ -1,1 +1,1 @@\n-a\n+b", added: 1, removed: 1 } });

test("itemsOfTurn keeps each row's tool id with its place; the session's set joins them", () => {
  const turn0 = itemsOfTurn({ gens: [{ tools: [row("a.rb", "t1"), row("b.rb", "t2")] }, { tools: [row("a.rb", "t3", "edit")] }] }, 0);
  assert.deepEqual(turn0[0].runs, [{ id: "t1", at: { turn: 0, step: 0, row: 0 } }, { id: "t3", at: { turn: 0, step: 1, row: 0 } }]);
  const turn1 = itemsOfTurn({ gens: [{ tools: [row("a.rb", "t9")] }] }, 1);
  const { items } = sessionItems({ turns: [turn0, turn1] });
  assert.deepEqual(items[0].runs.map((r) => r.id), ["t1", "t3", "t9"]);
  // A legacy row (no tool id): no runs.
  assert.equal(itemsOfTurn({ gens: [{ tools: [{ ...row("c.rb", null) }] }] }, 0)[0].runs, undefined);
});

// The page's pieces as app.js wires them: the preview, then the working set
// with its peek, then attach.
function page({ answers = {}, sendLine = null, serverSet = () => ({ items: [], at: 0 }) } = {}) {
  const center = document.createElement("section");
  const stage = document.createElement("div");
  stage.id = "stage";
  center.append(stage);
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(center, historyEl, infoEl);
  const asked = [];
  const latestAsked = [];
  let session = "s1";
  const getItem = (id, kind, key, opts = {}) => {
    asked.push([id, kind, key, !!opts.now]);
    latestAsked.push(!!opts.latest);
    const found = answers[`${kind}:${key}`];
    const answer = typeof found === "function" ? found() : found;
    return answer instanceof Promise ? answer : Promise.resolve(answer || { kind, key, events: [] });
  };
  const preview = createWorkingSetPreview({ centerEl: center, session: () => session, state: () => ({ dir: "/p" }), getItem, sendLine });
  const ws = createWorkingSet({
    historyEl, infoEl, state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [], dir: "/p" }), session: () => session,
    getWorkingSet: () => Promise.resolve(serverSet()), peek: preview.peek, onTimeline: preview.open,
  });
  preview.attach(ws);
  const memoryRow = { tool: "memory_read", title: "style", status: "ok", tool_id: "t5" };
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [row("a.rb", "t1"), row("b.rb", "t2")] }, { tools: [row("a.rb", "t3", "edit"), memoryRow] }] }, 0), prompt: "go" }]);
  const cleanup = () => { center.remove(); historyEl.remove(); infoEl.remove(); ws.popover.pop.remove(); setTimelineWayIn(false); };
  return { center, stage, ws, preview, asked, latestAsked, cleanup, setSession: (id) => { session = id; } };
}

test("the peek: a row's ▸ asks the item route and shows the latest edit, its link opens the reader", async () => {
  const answers = { "file:/p/a.rb": { kind: "file", key: "/p/a.rb", events: [readEvent("t1", 1, 30), editEvent("t3")] } };
  const p = page({ answers });
  p.ws.popover.open(document.querySelector(".ws-chip"));
  const pop = p.ws.popover.pop;
  const toggle = pop.querySelector('.ws-row[data-ws-id="file:/p/a.rb"] .ws-peek-toggle');
  assert.ok(toggle, "a row gets its ▸");
  toggle.click();
  await tick();
  assert.deepEqual(p.asked, [["s1", "file", "/p/a.rb", false]]);
  const peek = pop.querySelector(".ws-peek");
  assert.match(peek.querySelector(".ws-peek-t").textContent, /latest · edit at t1·s2/);
  assert.ok(peek.querySelector(".diff .diff-add"));
  assert.match(peek.querySelector(".ws-peek-open").textContent, /Open the timeline · 1 read, 1 edit/);
  assert.equal(peek.querySelector(".wsr-call").dataset.at, "0.1.0", "go to the call: the edit's row");
  assert.equal(pop.querySelector(".ws-peek-toggle").getAttribute("aria-expanded"), "true");

  peek.querySelector(".ws-peek-open").click();
  await tick();
  assert.equal(p.ws.isOpen(), false, "the popover closes");
  const reader = p.center.querySelector("#wsReader");
  assert.equal(reader.hidden, false);
  assert.equal(p.stage.inert, true, "the stage stays under it, inert");
  assert.deepEqual(p.asked.at(-1), ["s1", "file", "/p/a.rb", false]);
  assert.deepEqual([...reader.querySelectorAll(".wsr-card")].map((c) => c.className), ["wsr-card edit latest", "wsr-card slice"]);
  assert.ok(reader.querySelector(".wsr-item.on").textContent.includes("a.rb"));
  assert.ok(reader.querySelector(".wsr-strip .wsr-band"));

  // ↓ the next item; Esc back to the stage.
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  await tick();
  assert.ok(reader.querySelector(".wsr-item.on").textContent.includes("b.rb"));
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.equal(reader.hidden, true);
  assert.equal(p.stage.inert, false);
  p.cleanup();
});

// The open item's server signature (count, ops, tokens, state, has_drop, pinned) decides a refetch.
const serverA = (count, extra = {}) => ({ items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 3, ops: ["read"], count, ...extra }], at: 4 + count });

test("the peek asks for the latest only, and again only when the open item's server signature changed", async () => {
  let answer = { kind: "file", key: "/p/a.rb", events: [readEvent("t1", 1, 3)], counts: { read: 3, edit: 1 }, latest: true };
  const p = page({ answers: { "file:/p/a.rb": () => answer } });
  p.ws.update(serverA(1));
  p.ws.popover.open(document.querySelector(".ws-chip"));
  const pop = p.ws.popover.pop;
  pop.querySelector('.ws-row[data-ws-id="file:/p/a.rb"] .ws-peek-toggle').click();
  await tick();
  assert.deepEqual(p.latestAsked, [true]);
  assert.match(pop.querySelector(".ws-peek-open").textContent, /Open the timeline · 3 reads, 1 edit/, "the answer's counts, not its events'");

  // Another file's read: the open item's signature is the same, nothing asked.
  p.ws.update({ items: [...serverA(1).items, { kind: "file", key: "/p/b.rb", state: "live", tokens: 2, ops: ["read"], count: 1 }], at: 9 });
  await tick();
  assert.equal(p.asked.length, 1);
  // A new read of it raises its count: asked again, drawn.
  answer = { kind: "file", key: "/p/a.rb", events: [readEvent("t4", 10, 12)], counts: { read: 4, edit: 1 }, latest: true };
  p.ws.update(serverA(2));
  await tick();
  assert.equal(p.asked.length, 2);
  assert.match(pop.querySelector(".ws-peek-t").textContent, /latest · read 10–12/);
  p.ws.popover.close();
  p.cleanup();
});

test("an older answer is dropped within one running turn, and taken at running → idle", async () => {
  const answers = [
    { kind: "file", key: "/p/a.rb", events: [readEvent("t4", 10, 12)], running: true, turn_id: "T", at: 20 },
    { kind: "file", key: "/p/a.rb", events: [readEvent("t1", 1, 3)], running: true, turn_id: "T", at: 12 },
    { kind: "file", key: "/p/a.rb", events: [readEvent("t5", 5, 6)], running: false, at: 8 },
  ];
  let n = 0;
  const p = page({ answers: { "file:/p/a.rb": () => answers[n++] } });
  p.ws.update(serverA(1));
  p.preview.open({ kind: "file", key: "/p/a.rb" });
  await tick();
  const reader = p.center.querySelector("#wsReader");
  const lines = () => [...reader.querySelectorAll(".wsr-card .read-line")].map((l) => l.dataset.line);
  assert.deepEqual(lines(), ["10", "11", "12"]);
  p.ws.update(serverA(2));
  await tick();
  assert.deepEqual(lines(), ["10", "11", "12"], "at 12 < 20 in turn T: dropped");
  p.ws.update(serverA(3));
  await tick();
  assert.deepEqual(lines(), ["5", "6"], "the idle answer is taken though its at is lower");
  p.preview.close();
  p.cleanup();
});

test("the reader asks again on a GET answer or an event only when the open item's signature changed", async () => {
  const p = page({ serverSet: () => ({ ...serverA(1), at: 40 }) });
  p.ws.update(serverA(1));
  p.preview.open({ kind: "file", key: "/p/a.rb" });
  await tick();
  assert.equal(p.asked.length, 1);
  p.ws.update({ ...serverA(1), at: 30 });
  p.ws.seed([]);
  await tick();
  await tick();
  assert.equal(p.asked.length, 1, "same signature: an event and a GET answer ask nothing");
  p.ws.update(serverA(1, { tokens: 1 }));
  await tick();
  assert.equal(p.asked.length, 2, "its tokens changed (a forget): asked again");
  p.preview.close();
  p.cleanup();
});

test("the reader opened by a key no row has (a full URL) still asks again when the server's item changes", async () => {
  const url = `https://example.com/${"long/".repeat(30)}page`;
  const urlSet = (count) => ({ items: [{ kind: "url", key: url, state: "live", tokens: 9, ops: ["fetch"], count }], at: 4 + count });
  const p = page();
  p.ws.update(urlSet(1));
  p.preview.open({ kind: "url", key: url });
  await tick();
  assert.equal(p.asked.length, 1);
  p.ws.update({ ...urlSet(1), at: 30 });
  await tick();
  assert.equal(p.asked.length, 1, "unchanged: nothing asked");
  p.ws.update(urlSet(2));
  await tick();
  assert.equal(p.asked.length, 2, "a new fetch of it: asked again");
  p.preview.close();
  p.cleanup();
});

test("the reader drops an answer for an item no longer open, and closes on another session's snapshot", async () => {
  let release;
  const slow = new Promise((resolve) => { release = resolve; });
  const answers = { "file:/p/a.rb": slow, "file:/p/b.rb": { kind: "file", key: "/p/b.rb", events: [readEvent("t2", 1, 3)] } };
  const p = page({ answers });
  p.preview.open({ kind: "file", key: "/p/a.rb" });
  p.preview.open({ kind: "file", key: "/p/b.rb" });
  await tick();
  release({ kind: "file", key: "/p/a.rb", events: [editEvent("t3")] });
  await tick();
  const reader = p.center.querySelector("#wsReader");
  assert.deepEqual([...reader.querySelectorAll(".wsr-card")].map((c) => c.className), ["wsr-card slice latest"], "a.rb's late answer is dropped");
  p.setSession("s2");
  p.ws.update({ items: [], at: 1 });
  assert.equal(reader.hidden, true, "another session's snapshot closes it");
  p.cleanup();
});

test("a dropped slice is greyed with undrop, which posts the line", async () => {
  const lines = [];
  const answers = { "file:/p/a.rb": { kind: "file", key: "/p/a.rb", events: [readEvent("t1", 1, 5, { sent: false, dropped: true })] } };
  const p = page({ answers, sendLine: (line) => lines.push(line) });
  p.ws.update({ items: [{ kind: "file", key: "/p/a.rb", state: "dropped", tokens: 3, has_drop: true }], at: 4 });
  p.preview.open({ kind: "file", key: "/p/a.rb" });
  await tick();
  const reader = p.center.querySelector("#wsReader");
  const card = reader.querySelector(".wsr-card");
  assert.match(card.className, /gone dropped/);
  assert.match(card.querySelector(".wsr-gone").textContent, /5 lines · dropped by you/);
  card.querySelector('[data-wsr="undrop"]').click();
  assert.deepEqual(lines, ["/working-set undrop a.rb"]);
  p.preview.close();
  p.cleanup();
});

test("a stale memory: What chi has, and Now · diff from the route's now", async () => {
  const memory = { scope: "project", path: "/m/projects/x/style.md", overlay_path: null, overlay: null };
  const answers = {
    "memory:style": { kind: "memory", key: "style", events: [{ tool_id: "t5", op: "memory_read", step: 3, sent: true, text: "be brief\n", memory, shared_with: [] }],
      now: { text: "be very brief\n", diff: { text: "@@ -1,1 +1,1 @@\n-be brief\n+be very brief", added: 1, removed: 1 }, gone: false } },
  };
  const p = page({ answers });
  p.ws.update({ items: [{ kind: "memory", key: "style", state: "stale", tokens: 3 }], at: 4 });
  p.preview.open({ kind: "memory", key: "style" });
  await tick();
  assert.deepEqual(p.asked.at(-1), ["s1", "memory", "style", true]);
  const reader = p.center.querySelector("#wsReader");
  assert.match(reader.querySelector(".wsr-banner").textContent, /Changed since chi's last read/);
  assert.match(reader.querySelector(".wsr-card.memory .wsr-text").textContent, /be brief/);
  assert.match(reader.querySelector(".wsr-from").textContent, /project memory · from \/m\/projects\/x\//);
  reader.querySelector('[data-tab="now"]').click();
  assert.ok(reader.querySelector(".wsr-card.now .diff .diff-add"));
  p.preview.close();
  p.cleanup();
});

test("ways in: a tool row's timeline button once turned on, and the ref menu's What chi has for a file of the set", async () => {
  const holder = document.createElement("div");
  render(wayInTemplate(row("a.rb", "t1")), holder);
  assert.ok(holder.querySelector(".activity-ws") === null, "off: no button");
  const p = page();
  render(wayInTemplate({ tool: "memory_read", title: "style", status: "ok" }), holder);
  const button = holder.querySelector(".activity-ws");
  assert.deepEqual([button.dataset.wsKind, button.dataset.wsKey], ["memory", "style"]);
  document.body.append(holder);
  button.click();
  await tick();
  assert.equal(p.center.querySelector("#wsReader").hidden, false);
  p.preview.close();

  const ref = document.createElement("span");
  ref.className = "ref";
  ref.dataset.refKind = "file";
  ref.dataset.refPath = "/p/a.rb";
  document.body.append(ref);
  const env = { whatChiHas: p.preview.whatChiHas };
  const ids = (target) => refActions(target, { editor: false }, REF_ACTIONS, env).map((a) => a.id);
  // Secondary: never a ref's main target, so alone it changes nothing.
  assert.deepEqual(ids(refTarget(ref)), []);
  const withEditor = refActions(refTarget(ref), { editor: true, editorUrl: "vscode://file{path}" }, REF_ACTIONS, env).map((a) => a.id);
  assert.deepEqual(withEditor, ["editor", "has", "copy"]);
  ref.dataset.refPath = "/p/elsewhere.rb";
  assert.ok(!refActions(refTarget(ref), { editor: true, editorUrl: "vscode://file{path}" }, REF_ACTIONS, env).some((a) => a.id === "has"));
  ref.remove();
  holder.remove();
  p.cleanup();
});

test("a participant's list (no peek): no ▸", () => {
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(infoEl);
  const ws = createWorkingSet({
    historyEl: document.createElement("div"), infoEl, state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [] }), session: () => "s1",
  });
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [row("a.rb", "t1")] }] }, 0), prompt: "go" }]);
  ws.popover.open(infoEl.querySelector(".ws-chip"));
  assert.ok(ws.popover.pop.querySelector(".ws-row.file"));
  assert.ok(ws.popover.pop.querySelector(".ws-peek-toggle") === null);
  ws.popover.close();
  ws.popover.pop.remove();
  infoEl.remove();
});

test("forgetting the session resets the reader: closed, the stage no longer inert (session_view.js forgetSession)", async () => {
  const p = page();
  const opener = document.createElement("button");
  document.body.append(opener);
  opener.focus();
  p.preview.open({ kind: "file", key: "/p/a.rb" });
  await tick();
  assert.equal(p.stage.inert, true);
  p.preview.reset();
  assert.equal(p.center.querySelector("#wsReader").hidden, true);
  assert.equal(p.stage.inert, false, "the composer can be typed in again");
  assert.ok(document.activeElement !== opener, "a reset leaves focus alone");
  // A close (Esc) gives focus back to where it was at the open.
  opener.focus();
  p.preview.open({ kind: "file", key: "/p/a.rb" });
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.ok(document.activeElement === opener);
  opener.remove();
  p.cleanup();
});

test("↑↓ step over the rows the set draws: a muted memory is skipped", async () => {
  const p = page();
  const ws = p.ws;
  const items = ws.items;
  ws.items = () => [...items(), { kind: "memory", key: "muted", label: "muted", ops: [], muted: true }];
  p.preview.open({ kind: "memory", key: "style" });
  await tick();
  const reader = p.center.querySelector("#wsReader");
  assert.equal(reader.querySelector('[data-wsr="next"]').disabled, true, "style is the last drawn row");
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  assert.ok(reader.querySelector(".wsr-item.on").textContent.includes("style"));
  p.preview.close();
  p.cleanup();
});

test("What chi has comes after a row's other refs: never a file title's main target", () => {
  const env = { whatChiHas: { has: () => true, open: () => {} } };
  const target = { kind: "file", path: "/p/a.rb", line: null, isLine: false, actions: [], href: null,
    more: [{ kind: "issue", target: { id: "X-1" }, label: "X-1", actions: [{ id: "open", label: "Open", url: "https://x.test/X-1" }] }] };
  const ids = refActions(target, { editor: false }, REF_ACTIONS, env).map((a) => a.id);
  assert.deepEqual(ids, ["more:0:open", "has", "copy"]);
});
