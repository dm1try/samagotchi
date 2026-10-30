import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorkingSet, footprintNode, groupItems, stampHistory, stampRows } from "../../../lib/samagotchi/web/public/working_set_view.js";
import { itemsOfTurn } from "../../../lib/samagotchi/web/public/working_set.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { normalizeTiming, turnGroups } from "../../../lib/samagotchi/web/public/timing.js";
import { infoBarHtml, renderInfoBar, workingSetChipTemplate } from "../../../lib/samagotchi/web/public/info_bar.js";
import { handOffOrder } from "../../../lib/samagotchi/web/public/stage_model.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

const read = (path) => ({ tool: "read", title: path, ref: { kind: "file", path: `/p/${path}` }, params: `path="${path}"` });
// Two turns with saved parts: the first reads two files and a memory, the
// second only answers.
const items = [
  { role: "user", content: "first" },
  { role: "assistant", content: "Looking.", parts: { tools: [read("lib/a.rb"), { tool: "memory_read", title: "style" }] } },
  { role: "assistant", content: "", parts: { tools: [read("lib/b.rb")] } },
  { role: "assistant", content: "Done.", parts: {} },
  { role: "user", content: "second" },
  { role: "assistant", content: "Hi.", parts: {} },
];
const timing = normalizeTiming({ turn_records: [{ id: "T1", status: "completed", duration_ms: 5 }, { id: "T2", status: "completed", duration_ms: 5 }] });
const thumbs = () => "";

test("turnHistoryNodes with the working set: blocks and rows stamped with ordinals, a footprint after the block", () => {
  const out = turnHistoryNodes(items, timing, { thumbs, workingSet: true });
  const holder = document.createElement("div");
  holder.append(out);
  const block = holder.querySelector(".turn-work");
  assert.equal(block.dataset.turn, "0");
  assert.deepEqual([...block.querySelectorAll(".activity-row")].map((r) => r.dataset.at), ["0.0", "0.1", "1.0"]);
  const foot = block.nextElementSibling;
  assert.ok(foot.matches(".ws-foot"));
  assert.equal(foot.dataset.wsTurn, "0");
  assert.equal(foot.textContent.replace(/\s+/g, " ").trim(), "touched a.rb · ◆ style s1 · b.rb");
  assert.equal(foot.querySelector(".ws-step").dataset.at, "0.0.1");
  // The flag off: no stamps, no footprint.
  const plain = document.createElement("div");
  plain.append(turnHistoryNodes(items, timing, { thumbs }));
  assert.equal(plain.querySelectorAll(".ws-foot, [data-turn], [data-at]").length, 0);
});

test("groupItems: a reloaded turn's items as the history numbers them", () => {
  const [g] = turnGroups(items, timing).filter((x) => x.kind === "turn");
  assert.deepEqual(groupItems(g, 0).map((i) => [i.key, i.at]), [
    ["/p/lib/a.rb", { turn: 0, step: 0, row: 0 }], ["style", { turn: 0, step: 0, row: 1 }], ["/p/lib/b.rb", { turn: 0, step: 1, row: 0 }],
  ]);
});

test("stampRows: the live block's turn and each row's step.row, found by its key", () => {
  const block = document.createElement("details");
  block.innerHTML = '<div class="activity-row" data-key="1:1"></div><div class="activity-row" data-key="2:1"></div><div class="activity-row" data-key="2:2"></div>';
  const turn = { gens: [{ tools: [{ key: "1:1" }] }, { tools: [{ key: "2:1" }, { key: "2:2" }] }] };
  stampRows(block, turn, 4);
  assert.equal(block.dataset.turn, "4");
  assert.deepEqual([...block.children].map((r) => r.dataset.at), ["0.0", "1.0", "1.1"]);
  stampHistory([block], [7]);
  assert.equal(block.dataset.turn, "7");
});

test("footprintNode: a line for a turn that touched something, none otherwise; handOffOrder puts it after the block", () => {
  const its = itemsOfTurn({ gens: [{ tools: [{ ...read("lib/x.rb"), status: "ok" }] }] }, 2);
  const foot = footprintNode(its, 2);
  assert.equal(foot.getAttribute("role"), "button");
  assert.match(foot.getAttribute("aria-label"), /^Working set of this turn: x\.rb\. Open the list\.$/);
  assert.equal(footprintNode([], 2), null);
  assert.deepEqual(handOffOrder({ prompt: "P", block: "B", footprint: "F", answer: ["A"] }), ["P", "B", "F", "A"]);
});

const bar = (extra = {}) => ({
  id: "abcdef123", status: "idle", model: { text: "m", title: "m" }, chain: {}, memories: ["a", "b"], preloaded: ["p"], muted: [],
  dir: "~/x", ctx: { text: "ctx 1%", tip: "" }, ...extra,
});

test("the info bar: off, the mem chip and the memories tooltip; on, the set chip in its place and no tooltip", () => {
  const div = document.createElement("div");
  renderInfoBar(div, bar());
  assert.equal(div.querySelector(".mem-chip").textContent, "mem 2");
  assert.equal(div.querySelector(".ws-chip"), null);
  assert.match(div.title, /^memories: a, b/);
  renderInfoBar(div, bar({ workingSet: { chip: { n: 5, changed: true } } }));
  assert.equal(div.querySelector(".mem-chip"), null);
  assert.equal(div.querySelector(".ws-chip").textContent, "set 5");
  assert.ok(div.querySelector(".ws-chip").classList.contains("changed"));
  assert.equal(div.title, "");
  // An empty set: "set 0", muted, from the session's start (no mem chip).
  renderInfoBar(div, bar({ workingSet: { chip: { n: 0, changed: false } } }));
  assert.equal(div.querySelector(".ws-chip").textContent, "set 0");
  assert.ok(div.querySelector(".ws-chip").classList.contains("empty"));
  assert.match(div.querySelector(".ws-chip").title, /^Working set: nothing this session brought into context yet /);
  assert.equal(div.querySelector(".mem-chip"), null);
  // The status word in its own span (its sizers are CSS's): the text is the word alone.
  assert.equal(div.querySelector(".status").textContent, "idle");
  const frag = document.createElement("div");
  render(workingSetChipTemplate({ n: 1, changed: false }), frag);
  assert.equal(frag.querySelector(".ws-chip").textContent, "set 1");
  assert.match(frag.querySelector(".ws-chip").title, /^Working set: 1 item /);
  assert.ok(infoBarHtml(null));
});

test("the server's snapshot: kept by its at, overlaid on every form, the footprints redrawn in place, the rail told", async () => {
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(historyEl, infoEl);
  const asked = [];
  let answer = { items: [], at: 1 };
  const ws = createWorkingSet({
    historyEl, infoEl, state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [] }), session: () => "s1",
    getWorkingSet: (id) => { asked.push(id); return Promise.resolve(answer); },
  });
  const turnItems = itemsOfTurn({ gens: [{ tools: [{ ...read("lib/a.rb"), status: "ok" }, { ...read("lib/b.rb"), status: "ok" }] }] }, 0);
  const foot = footprintNode(turnItems, 0);
  historyEl.append(foot);
  let railRedraws = 0;
  ws.onServer(() => { railRedraws += 1; });

  ws.seed([{ items: turnItems, prompt: "first" }]);
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(asked, ["s1"], "a seed asks the server");
  assert.equal(railRedraws, 1, "its answer is the first snapshot");
  railRedraws = 0;

  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "forgotten", tokens: 9 }], at: 6 });
  assert.equal(historyEl.querySelector(".ws-foot"), foot, "the same node, drawn again in place");
  assert.ok(foot.querySelector(".l.forgotten"));
  assert.equal(foot.querySelector(".f").textContent, "1 forgotten");
  assert.equal(railRedraws, 1);
  // The live turn's items (the rail's) get the state too.
  const live = ws.liveItems({ gens: [{ tools: [{ ...read("lib/a.rb"), status: "ok" }] }] });
  assert.equal(live.items[0].state, "forgotten");

  // A turn-end stale (the rail is gone by then): the footprint says it.
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "stale", tokens: 90 }], at: 7 });
  assert.ok(foot.querySelector(".l.stale"));
  assert.equal(foot.querySelector(".s").textContent, "1 stale");
  assert.equal(foot.querySelector(".f"), null);

  // A newer one where it is live again: the strike goes.
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 90 }], at: 8 });
  assert.equal(foot.querySelector(".l.forgotten"), null);
  assert.equal(foot.querySelector(".f"), null);
  assert.equal(foot.querySelector(".s"), null);
  historyEl.remove();
  infoEl.remove();
});

// A view over session s1 whose GETs answer when the test says (+answer(i,
// snapshot)+ resolves the i-th), the overlay read off a live turn's a.rb.
function deferredView() {
  const pending = [];
  const ws = createWorkingSet({
    historyEl: document.createElement("div"), infoEl: document.createElement("div"),
    state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [] }), session: () => "s1",
    getWorkingSet: () => new Promise((resolve) => { pending.push(resolve); }),
  });
  const tick = () => new Promise((r) => setTimeout(r, 0));
  const answer = async (i, snapshot) => { await tick(); pending[i](snapshot); await tick(); };
  const stateOfA = () => ws.liveItems({ gens: [{ tools: [{ ...read("lib/a.rb"), status: "ok" }] }] }).items[0].state;
  return { ws, answer, stateOfA };
}
const aIs = (state, at, extra = {}) => ({ items: [{ kind: "file", key: "/p/lib/a.rb", state, tokens: 9 }], at, ...extra });

test("the server's snapshot after a rollback: the emptied (or smaller) event is taken, and so is a GET's answer", async () => {
  const { ws, answer, stateOfA } = deferredView();
  ws.seed([]);
  await answer(0, aIs("stale", 6));
  assert.equal(stateOfA(), "stale");
  // A rollback took the read away: the one empty event, at a smaller at.
  ws.update({ items: [], at: 2 });
  assert.equal(stateOfA(), "live", "the stale state went with the read");
  ws.update(aIs("forgotten", 9));
  // A rollback the page missed (a resync): the GET's smaller set wins.
  ws.seed([]);
  await answer(1, { items: [], at: 2, running: false });
  assert.equal(stateOfA(), "live");
});

test("the server's snapshot out of order: a GET an event overtook, or one behind a running turn, never wins", async () => {
  const { ws, answer, stateOfA } = deferredView();
  ws.seed([]);
  // The seed's GET is still on its way when the turn's event comes.
  ws.update(aIs("forgotten", 9));
  await answer(0, aIs("stale", 12));
  assert.equal(stateOfA(), "forgotten", "the event overtook the GET");
  // A GET asked during the turn: the session's messages, behind its events.
  ws.seed([]);
  await answer(1, aIs("stale", 6, { running: true }));
  assert.equal(stateOfA(), "forgotten");
  // Asked once the turn ended, no event meanwhile: the idle file change shows.
  ws.seed([]);
  await answer(2, aIs("stale", 9, { running: false }));
  assert.equal(stateOfA(), "stale");
});

test("the chip from the session's start: set 0 on an empty set, its count once a turn read something", () => {
  const ws = createWorkingSet({
    historyEl: document.createElement("div"), infoEl: document.createElement("div"), session: () => "s1",
    state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [], llmContext: null }),
    sendLine: () => Promise.resolve(),
  });
  ws.seed([]);
  assert.deepEqual(ws.chip(), { n: 0, changed: false });
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [{ ...read("lib/a.rb"), status: "ok" }] }] }, 0), prompt: "first" }]);
  assert.deepEqual(ws.chip(), { n: 1, changed: false }); // a seed (a load) sets no dot
});

// Steering (P3a): a view whose list is open, the lines it posts recorded.
function steeringView({ wide = true, llmContext = null, dir = undefined, paths = ["lib/a.rb", "lib/b.rb"] } = {}) {
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(infoEl);
  const sent = [];
  const win = { innerWidth: wide ? 1200 : 390, innerHeight: 800 };
  const ws = createWorkingSet({
    historyEl: document.createElement("div"), infoEl, session: () => "s1",
    state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [], llmContext, dir }),
    sendLine: (line) => { sent.push(line); return Promise.resolve(); },
  });
  const turn = itemsOfTurn({ gens: [{ tools: paths.map((path) => ({ ...read(path), status: "ok" })) }] }, 0);
  ws.seed([{ items: turn, prompt: "first" }]);
  ws.update({ items: paths.map((path, i) => ({ kind: "file", key: `/p/${path}`, state: "live", tokens: i ? 9 : 40 })), at: 4 });
  const pop = ws.popover.pop;
  if (!wide) Object.defineProperty(window, "innerWidth", { value: 390, configurable: true });
  ws.popover.open(infoEl.querySelector(".ws-chip"));
  const row = (name) => [...pop.querySelectorAll(".ws-row[data-ws-id]")].find((r) => r.querySelector(".t")?.textContent === name);
  return { ws, pop, sent, row, win, infoEl };
}

test("the list's drop posts the session's /working-set line; a dropped row offers undrop", () => {
  const { ws, pop, sent, row, infoEl } = steeringView();
  row("a.rb").querySelector('[data-ws="steer"]').click();
  assert.deepEqual(sent, ["/working-set drop /p/lib/a.rb"]);
  // Between turns it ran at once: the re-emitted set strikes it.
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "dropped", tokens: 12 }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9 }], at: 4 });
  const dropped = row("a.rb");
  assert.ok(dropped.classList.contains("dropped"));
  assert.match(dropped.querySelector(".st").textContent, /dropped/);
  const undrop = dropped.querySelector('[data-op="undrop"]');
  assert.match(undrop.title, /cache break/);
  undrop.click();
  assert.equal(sent.at(-1), "/working-set undrop /p/lib/a.rb");
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("inside the session's folder a line names a file by its relative path (the bubble shows it); pending reads both", () => {
  const { ws, pop, sent, row, infoEl } = steeringView({ dir: "/p/" });
  row("a.rb").querySelector('[data-ws="steer"]').click();
  assert.deepEqual(sent, ["/working-set drop lib/a.rb"]);
  ws.commandQueued({ command_id: "c1", line: "/working-set drop lib/a.rb", waits: "turn_end" });
  ws.commandQueued({ command_id: "c2", line: "/working-set drop /p/lib/b.rb", waits: "turn_end" });
  assert.equal(row("a.rb").querySelector(".ws-pend").textContent, "drops next turn");
  assert.equal(row("b.rb").querySelector(".ws-pend").textContent, "drops next turn");
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("a file whose path has a space: its drop posts the path quoted, and its pending op marks the row", () => {
  const { ws, pop, sent, row, infoEl } = steeringView({ dir: "/p", paths: ["my notes/a b.md", "lib/b.rb"] });
  row("a b.md").querySelector('[data-ws="steer"]').click();
  assert.deepEqual(sent, ['/working-set drop "my notes/a b.md"']);
  ws.commandQueued({ command_id: "c1", line: sent[0], waits: "turn_end" });
  assert.equal(row("a b.md").querySelector(".ws-pend").textContent, "drops next turn");
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("pending ops come from command_queued (any client's), net with their inverse, clear at command_ran; undo and undo all", () => {
  const { ws, pop, sent, row, infoEl } = steeringView();
  let railDraws = 0;
  ws.onServer(() => { railDraws += 1; });
  ws.commandQueued({ command_id: "c1", line: "/working-set drop /p/lib/a.rb /p/lib/b.rb", waits: "turn_end", client_id: "other" });
  ws.commandQueued({ command_id: "c0", line: "/model x", waits: "turn_end" });
  assert.equal(railDraws, 1, "a pending op redraws the rail's marks");
  const a = row("a.rb");
  assert.ok(a.classList.contains("pending"));
  assert.equal(a.querySelector(".ws-pend").textContent, "drops next turn");
  assert.match(pop.querySelector(".ws-pending").textContent, /^2 changes pending · apply at the next turn's start\s*undo all/);
  a.querySelector('[data-ws="steer"]').click();
  assert.equal(sent.at(-1), "/working-set undrop /p/lib/a.rb", "undo: the inverse, queued after it");
  ws.commandQueued({ command_id: "c2", line: "/working-set undrop /p/lib/a.rb", waits: "turn_end" });
  assert.equal(row("a.rb").classList.contains("pending"), false, "a drop then its undrop: nothing pending");
  assert.match(pop.querySelector(".ws-pending").textContent, /^1 change pending/);
  pop.querySelector('[data-ws="undo-all"]').click();
  assert.equal(sent.at(-1), "/working-set undrop /p/lib/b.rb");
  ws.commandRan({ command_id: "c1" });
  ws.commandRan({ command_id: "c2" });
  assert.equal(pop.querySelector(".ws-pending"), null);
  // A reload's seed drops them: the snapshot's replay brings them again.
  ws.commandQueued({ command_id: "c3", line: "/working-set drop /p/lib/b.rb", waits: "turn_end" });
  assert.equal(ws.pending().size, 1);
  ws.seed([]);
  assert.equal(ws.pending().size, 0);
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("pin shows only under forget; a pinned row has its 📌, unpin and a greyed drop, under any strategy", () => {
  const none = steeringView();
  assert.equal(none.pop.querySelector('[data-op="pin"]'), null, "no forget layer: no pin");
  none.ws.popover.close();
  none.infoEl.remove();
  none.pop.remove();

  const { ws, pop, sent, row, infoEl } = steeringView({ llmContext: { strategy: "stale,forget" } });
  assert.match(pop.querySelector(".ws-hint").textContent, /Pin keeps an item from the model's forget/);
  row("a.rb").querySelector('[data-op="pin"]').click();
  assert.equal(sent.at(-1), "/working-set pin /p/lib/a.rb");
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 40, pinned: true }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9 }], at: 4 });
  const a = row("a.rb");
  assert.ok(a.querySelector(".ws-pin"));
  assert.equal(a.querySelector('[data-op="drop"]').disabled, true);
  assert.equal(a.querySelector('[data-op="drop"]').title, "pinned by the user: unpin it first");
  a.querySelector('[data-op="unpin"]').click();
  assert.equal(sent.at(-1), "/working-set unpin /p/lib/a.rb");
  // Queued while a turn runs: pending until its command_ran, undo is the unpin.
  ws.commandQueued({ command_id: "p1", line: "/working-set pin /p/lib/b.rb", waits: "turn_end" });
  assert.equal(row("b.rb").querySelector(".ws-pend").textContent, "applies next turn");
  // A drop queued after it (another client's) is refused by the worker: the pin stays pending (no drop offered).
  ws.commandQueued({ command_id: "p2", line: "/working-set drop /p/lib/b.rb", waits: "turn_end" });
  assert.equal(row("b.rb").querySelector(".ws-pend").textContent, "applies next turn");
  assert.equal(row("b.rb").querySelector('[data-op="drop"]'), null);
  // A pinned row's queued drop isn't pending either.
  ws.commandQueued({ command_id: "p3", line: "/working-set drop /p/lib/a.rb", waits: "turn_end" });
  assert.equal(row("a.rb").querySelector(".ws-pend"), null);
  assert.equal(row("a.rb").querySelector('[data-op="drop"]').disabled, true);
  row("b.rb").querySelector('[data-ws="steer"]').click();
  assert.equal(sent.at(-1), "/working-set unpin /p/lib/b.rb");
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("a strategy change (/llm-context's command_ran) redraws the open list: pin comes and goes with forget", () => {
  const llmContext = { strategy: "none" };
  const { ws, pop, row, infoEl } = steeringView({ llmContext });
  assert.equal(row("a.rb").querySelector('[data-op="pin"]'), null);
  llmContext.strategy = "stale,forget";
  ws.strategyChanged();
  assert.ok(row("a.rb").querySelector('[data-op="pin"]'));
  llmContext.strategy = "none";
  ws.strategyChanged();
  assert.equal(row("a.rb").querySelector('[data-op="pin"]'), null);
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("an item holding the user's drop on some reads (has_drop) offers undrop: alone when forgotten, beside drop when partly sent", () => {
  const { ws, pop, sent, row, infoEl } = steeringView({ llmContext: { strategy: "stale,forget" } });
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "forgotten", tokens: 12, has_drop: true }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9, has_drop: true }], at: 6 });
  assert.deepEqual([...row("a.rb").querySelectorAll("button.ws-act-b")].map((b) => b.textContent), ["undrop"]);
  assert.deepEqual([...row("b.rb").querySelectorAll("button.ws-act-b")].map((b) => b.textContent), ["drop", "undrop"]);
  row("a.rb").querySelector('[data-op="undrop"]').click();
  assert.equal(sent.at(-1), "/working-set undrop /p/lib/a.rb");
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("a pinned row keeps its unpin without the forget layer (its drop waits for it)", () => {
  const { ws, pop, row, infoEl } = steeringView();
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 40, pinned: true }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9 }], at: 4 });
  assert.ok(row("a.rb").querySelector(".ws-pin"));
  assert.ok(row("a.rb").querySelector('[data-op="unpin"]'));
  assert.equal(row("b.rb").querySelector('[data-op="pin"]'), null);
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("a phone's sheet: a tap on a row opens its action strip under it, one at a time", () => {
  const { ws, pop, sent, row, infoEl } = steeringView({ wide: false });
  try {
    assert.ok(pop.classList.contains("sheet"));
    row("a.rb").querySelector(".st").click();
    const strip = pop.querySelector(".ws-strip");
    assert.ok(strip);
    assert.deepEqual([...strip.querySelectorAll("button")].map((b) => b.textContent), ["drop", "open"]);
    row("b.rb").querySelector(".st").click();
    assert.equal(pop.querySelectorAll(".ws-strip").length, 1);
    assert.ok(row("b.rb").classList.contains("strip-open"));
    pop.querySelector(".ws-strip [data-ws=\"steer\"]").click();
    assert.equal(sent.at(-1), "/working-set drop /p/lib/b.rb");
  } finally {
    ws.popover.close();
    infoEl.remove();
    pop.remove();
    delete window.innerWidth;
  }
});

test("+ add: the list's foot posts what was typed; the added item is a pending + row until the next turn sends its note", () => {
  const { ws, pop, sent, row, infoEl } = steeringView({ dir: "/p" });
  try {
    const input = pop.querySelector(".ws-add .ws-add-in");
    assert.ok(input, "the foot's input");
    input.value = "lib/new file.rb";
    pop.querySelector(".ws-add").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
    assert.deepEqual(sent, ['/working-set add "lib/new file.rb"']);
    assert.equal(pop.querySelector(".ws-add-in").value, "");
    // Between turns it ran at once: the re-announced set carries it in adds.
    ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 40 }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9 }],
      at: 5, adds: [{ kind: "file", key: "/p/lib/new file.rb", label: "lib/new file.rb" }] });
    const added = row("lib/new file.rb");
    assert.ok(added.classList.contains("added") && added.classList.contains("pending"));
    assert.equal(added.querySelector(".k").textContent, "+");
    assert.equal(added.querySelector(".ws-pend").textContent, "reads next turn");
    assert.match(pop.querySelector(".ws-pending").textContent, /^1 change pending/);
    added.querySelector('[data-ws="steer"]').click();
    assert.equal(sent.at(-1), '/working-set unadd "lib/new file.rb"', "undo: unadd");
    // Mid-turn a queued add is pending from its line; its unadd nets it.
    ws.commandQueued({ command_id: "c1", line: "/working-set add memory:style", waits: "turn_end" });
    assert.ok(row("style").classList.contains("pending"));
    // The next turn's first request sent the note: no adds, nothing pending.
    ws.commandRan({ command_id: "c1" });
    ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 40 }], at: 7 });
    assert.equal(row("lib/new file.rb"), undefined);
    assert.equal(pop.querySelector(".ws-pending"), null);
  } finally {
    ws.popover.close();
    infoEl.remove();
    pop.remove();
  }
});

test("a stale or forgotten row offers refresh (an add of it); pending, it reads `reads next turn`", () => {
  const { ws, pop, sent, row, infoEl } = steeringView();
  try {
    ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "stale", tokens: 40 }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9 }], at: 5 });
    assert.equal(row("b.rb").querySelector('[data-op="add"]'), null);
    const refresh = row("a.rb").querySelector('[data-op="add"]');
    assert.equal(refresh.textContent, "refresh");
    refresh.click();
    assert.equal(sent.at(-1), "/working-set add /p/lib/a.rb");
    ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "stale", tokens: 40 }], at: 6, adds: [{ kind: "file", key: "/p/lib/a.rb", label: "/p/lib/a.rb" }] });
    assert.equal(row("a.rb").querySelector(".ws-pend").textContent, "reads next turn");
    assert.equal(pop.querySelectorAll(".ws-row.added").length, 0, "held: no + row of its own");
  } finally {
    ws.popover.close();
    infoEl.remove();
    pop.remove();
  }
});
