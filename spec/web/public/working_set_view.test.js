import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorkingSet, footprintNode, groupItems, stampHistory, stampRows } from "../../../lib/samagotchi/web/public/working_set_view.js";
import { itemsOfTurn } from "../../../lib/samagotchi/web/public/working_set.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { normalizeTiming, turnGroups } from "../../../lib/samagotchi/web/public/timing.js";
import { drawnHistory } from "./drawn_history.js";
import { infoBarHtml, renderInfoBar, workingSetChipTemplate } from "../../../lib/samagotchi/web/public/info_bar.js";
import { handOffOrder } from "../../../lib/samagotchi/web/public/stage_model.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

const read = (path) => ({ tool: "read", title: path, ref: { kind: "file", path: `/p/${path}` }, params: `path="${path}"` });
// Two turns, drawn as chi web sends them (drawn_history.js): the first
// reads two files and a memory, the second only answers.
const { items, drawings } = drawnHistory([
  { role: "user", content: "first", turn_id: "T1" },
  { role: "assistant", content: "Looking.", parts: { tools: [read("lib/a.rb"), { tool: "memory_read", title: "style" }] } },
  { role: "assistant", content: "", parts: { tools: [read("lib/b.rb")] } },
  { role: "assistant", content: "Done.", parts: {} },
  { role: "user", content: "second", turn_id: "T2" },
  { role: "assistant", content: "Hi.", parts: {} },
]);
const timing = normalizeTiming({ turn_records: [{ id: "T1", status: "completed", duration_ms: 5 }, { id: "T2", status: "completed", duration_ms: 5 }] });
const thumbs = () => "";

test("turnHistoryNodes with the working set: blocks and rows stamped with ordinals, the footprint first on the block's summary line", () => {
  const out = turnHistoryNodes(items, timing, { thumbs, workingSet: true, drawings });
  const holder = document.createElement("div");
  holder.append(out);
  const block = holder.querySelector(".turn-work");
  assert.equal(block.dataset.turn, "0");
  assert.deepEqual([...block.querySelectorAll(".activity-row")].map((r) => r.dataset.at), ["0.0", "0.1", "1.0"]);
  const foot = block.querySelector(":scope > summary > .tw-sum > .ws-foot:first-child");
  assert.ok(foot.nextElementSibling.matches(".turn-steps"));
  assert.equal(block.nextElementSibling?.matches(".ws-foot") ?? false, false);
  assert.equal(foot.dataset.wsTurn, "0");
  assert.equal(foot.textContent.replace(/\s+/g, " ").trim(), "touched a.rb · ◆ style s1 · b.rb");
  assert.equal(foot.querySelector(".ws-step").dataset.at, "0.0.1");
  // The flag off: no stamps, no footprint.
  const plain = document.createElement("div");
  plain.append(turnHistoryNodes(items, timing, { thumbs, drawings }));
  assert.equal(plain.querySelectorAll(".ws-foot, [data-turn], [data-at]").length, 0);
});

test("groupItems: a reloaded turn's items as the history numbers them", () => {
  const [g] = turnGroups(items, timing, { drawings }).filter((x) => x.kind === "turn");
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

test("footprintNode: a span for a turn that touched something, none otherwise; handOffOrder has no place for it", () => {
  const its = itemsOfTurn({ gens: [{ tools: [{ ...read("lib/x.rb"), status: "ok" }] }] }, 2);
  const foot = footprintNode(its, 2);
  assert.equal(foot.tagName, "SPAN");
  assert.equal(foot.getAttribute("role"), "button");
  assert.match(foot.getAttribute("aria-label"), /^Working set of this turn: x\.rb\. Open the list\.$/);
  assert.ok(footprintNode([], 2) === null);
  assert.deepEqual(handOffOrder({ prompt: "P", block: "B", footprint: "F", answer: ["A"] }), ["P", "B", "A"]);
});

test("a footprint in a summary: a click cancels the summary's toggle, on its words and its step tag; elsewhere it cancels nothing", () => {
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  document.body.append(historyEl, infoEl);
  createWorkingSet({ historyEl, infoEl, state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [] }), session: () => "s1", getWorkingSet: () => Promise.resolve({ items: [], at: 0 }) });
  const its = itemsOfTurn({ gens: [{ tools: [{ ...read("lib/x.rb"), status: "ok" }] }, { tools: [{ tool: "memory_read", title: "style", status: "ok" }] }] }, 0);
  const inSummary = document.createElement("summary");
  inSummary.append(footprintNode(its, 0));
  const alone = footprintNode(its, 0);
  historyEl.append(inSummary, alone);
  const click = (el) => {
    const e = new window.MouseEvent("click", { bubbles: true, cancelable: true });
    el.dispatchEvent(e);
    document.querySelector("#workingSetPopover .ctx-pop-close")?.click();
    return e.defaultPrevented;
  };
  assert.equal(click(inSummary.querySelector(".w")), true);
  assert.equal(click(inSummary.querySelector(".ws-step")), true);
  assert.equal(click(alone.querySelector(".w")), false);
  historyEl.remove();
  infoEl.remove();
});

const bar = (extra = {}) => ({
  id: "abcdef123", status: "idle", model: { text: "m", title: "m" }, chain: {}, memories: ["a", "b"], preloaded: ["p"], muted: [],
  dir: "~/x", ctx: { text: "ctx 1%", tip: "" }, ...extra,
});

test("the info bar: off, the mem chip and the memories tooltip; on, the set chip in its place and no tooltip", () => {
  const div = document.createElement("div");
  renderInfoBar(div, bar());
  assert.equal(div.querySelector(".mem-chip").textContent, "mem 2");
  assert.ok(div.querySelector(".ws-chip") === null);
  assert.match(div.title, /^memories: a, b/);
  renderInfoBar(div, bar({ workingSet: { chip: { n: 5, changed: true } } }));
  assert.ok(div.querySelector(".mem-chip") === null);
  assert.equal(div.querySelector(".ws-chip").textContent, "set 5");
  assert.ok(div.querySelector(".ws-chip").classList.contains("changed"));
  assert.equal(div.title, "");
  // An empty set: "set 0", muted, from the session's start (no mem chip).
  renderInfoBar(div, bar({ workingSet: { chip: { n: 0, changed: false } } }));
  assert.equal(div.querySelector(".ws-chip").textContent, "set 0");
  assert.ok(div.querySelector(".ws-chip").classList.contains("empty"));
  assert.match(div.querySelector(".ws-chip").title, /^Working set: nothing this session brought into context yet /);
  assert.ok(div.querySelector(".mem-chip") === null);
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
  assert.ok(foot.querySelector(".f") === null);

  // A newer one where it is live again: the strike goes.
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 90 }], at: 8 });
  assert.ok(foot.querySelector(".l.forgotten") === null);
  assert.ok(foot.querySelector(".f") === null);
  assert.ok(foot.querySelector(".s") === null);
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
  assert.ok(pop.querySelector(".ws-pending") === null);
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
  assert.ok(none.pop.querySelector('[data-op="pin"]') === null, "no forget layer: no pin");
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
  assert.ok(row("b.rb").querySelector('[data-op="drop"]') === null);
  // A pinned row's queued drop isn't pending either.
  ws.commandQueued({ command_id: "p3", line: "/working-set drop /p/lib/a.rb", waits: "turn_end" });
  assert.ok(row("a.rb").querySelector(".ws-pend") === null);
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
  assert.ok(row("a.rb").querySelector('[data-op="pin"]') === null);
  llmContext.strategy = "stale,forget";
  ws.strategyChanged();
  assert.ok(row("a.rb").querySelector('[data-op="pin"]'));
  llmContext.strategy = "none";
  ws.strategyChanged();
  assert.ok(row("a.rb").querySelector('[data-op="pin"]') === null);
  ws.popover.close();
  infoEl.remove();
  pop.remove();
});

test("prompt notes update the open session list and count as in the prompt, not used", () => {
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(historyEl, infoEl);
  const current = { preloadedMemories: [], mutedMemories: [], usedMemories: [], promptNotes: [] };
  const ws = createWorkingSet({ historyEl, infoEl, state: () => current, session: () => "s1" });
  const pop = ws.popover.pop;
  ws.seed([{ items: itemsOfTurn({ gens: [{ tools: [{ tool: "memory_read", title: "model_notes_style", status: "ok" }] }] }, 0), prompt: "first" }]);
  ws.popover.open(infoEl.querySelector(".ws-chip"));
  current.promptNotes = [{ name: "model_notes_style" }];
  current.usedMemories = ["model_notes_style", "older"];
  ws.sessionChanged();
  const row = [...ws.popover.pop.querySelectorAll(".ws-row[data-ws-id]")].find((item) => item.dataset.wsId === "memory:model_notes_style");
  assert.ok(row);
  assert.equal(row.querySelector(".ws-step").textContent, "prompt");
  assert.equal(row.querySelector(".ws-step").title, "in the system prompt");
  assert.match(ws.popover.pop.querySelector(".ctx-pop-meta:not(.ws-size-line)").textContent, /1 used · 1 in the prompt/);
  assert.equal([...ws.popover.pop.querySelectorAll(".ws-row[data-ws-id]")].filter((item) => item.dataset.wsId === "memory:model_notes_style").length, 1);
  const withFile = itemsOfTurn({ gens: [{ tools: [{ ...read("lib/a.rb"), status: "ok" }, { tool: "memory_read", title: "model_notes_style", status: "ok" }] }] }, 0);
  ws.seed([{ items: withFile, prompt: "first" }]);
  assert.ok(ws.popover.pop.querySelector('[data-ws-id="memory:model_notes_style"]') === row);
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
  assert.ok(row("b.rb").querySelector('[data-op="pin"]') === null);
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
    assert.ok(row("lib/new file.rb") === undefined);
    assert.ok(pop.querySelector(".ws-pending") === null);
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
    assert.ok(row("b.rb").querySelector('[data-op="add"]') === null);
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

// Two turns over one list: turn 0 reads lib/a.rb and lib/b.rb, turn 1 edits
// lib/b.rb and reads lib/c.rb (the footprints are on the page).
function lensView({ files = null, state = {}, sendLine = null, turn1 = null, oneTurn = false } = {}) {
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(historyEl, infoEl);
  const ws = createWorkingSet({
    historyEl, infoEl, state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [], ...state }), session: () => "s1", sendLine,
  });
  const okRead = (path, tool = "read") => ({ ...read(path), tool, status: "ok" });
  const turn0 = itemsOfTurn({ gens: [{ tools: files ? files.map((f) => okRead(f)) : [okRead("lib/a.rb"), okRead("lib/b.rb")] }] }, 0);
  const turn1Items = itemsOfTurn(turn1 || { gens: [{ tools: [okRead("lib/c.rb")] }, { tools: [okRead("lib/b.rb", "edit")] }] }, 1);
  const lists = [{ items: turn0, prompt: "first" }, { items: turn1Items, prompt: "second" }].slice(0, oneTurn ? 1 : 2);
  ws.seed(lists);
  const foots = [footprintNode(turn0, 0), footprintNode(turn1Items, 1)];
  historyEl.append(...foots);
  const pop = ws.popover.pop;
  const rows = () => [...pop.querySelectorAll(".ws-row[data-ws-id]")];
  const lit = () => rows().filter((r) => r.classList.contains("lit")).map((r) => r.querySelector(".t").textContent);
  const dim = () => rows().filter((r) => r.classList.contains("dim")).map((r) => r.querySelector(".t").textContent);
  const lensBtn = (which) => pop.querySelector(`[data-ws="lens"][data-lens="${which}"]`);
  const done = () => { ws.popover.close(); infoEl.remove(); historyEl.remove(); pop.remove(); };
  return { ws, pop, rows, lit, dim, lensBtn, foots, infoEl, done, lists, okRead };
}

test("a footprint opens the turn lens: the list is the session's, the turn's rows lit with its step tags, the rest dimmed", () => {
  const v = lensView();
  try {
    v.foots[1].click();
    assert.ok(v.ws.isOpen());
    assert.deepEqual(v.rows().map((r) => r.querySelector(".t").textContent), ["a.rb", "b.rb", "c.rb"], "always the session's list");
    assert.deepEqual(v.lit(), ["b.rb", "c.rb"]);
    assert.deepEqual(v.dim(), ["a.rb"]);
    assert.equal(v.pop.querySelector(".ws-lens-line").textContent, "turn 2 touched 2 · 1 new");
    // b.rb's step tag and words are the turn's (step 2, edited), not the session's first entry (t1·s1, read).
    const b = v.rows().find((r) => r.dataset.wsId === "file:/p/lib/b.rb");
    assert.equal(b.querySelector(".ws-step").textContent, "s2");
    assert.equal(b.querySelector(".ws-step").dataset.at, "1.1.0");
    assert.match(b.querySelector(".st").textContent, /edited/);
    assert.equal(v.rows()[0].querySelector(".ws-step").textContent, "t1·s1", "an untouched row keeps the session's own tag");
    // The session lens: no lit, no dim, no line.
    v.lensBtn("session").click();
    assert.deepEqual([v.lit(), v.dim()], [[], []]);
    assert.ok(v.pop.querySelector(".ws-lens-line") === null);
    assert.equal(v.rows().find((r) => r.dataset.wsId === "file:/p/lib/b.rb").querySelector(".ws-step").textContent, "t1·s1");
  } finally { v.done(); }
});

test("‹ › step through the turns, disabled at the ends; the turn button takes the newest turn from the session lens", () => {
  const v = lensView();
  try {
    v.foots[0].click();
    assert.equal(v.pop.querySelector(".ws-lens-line").textContent, "turn 1 touched 2 · 2 new");
    assert.deepEqual(v.lit(), ["a.rb", "b.rb"]);
    assert.equal(v.lensBtn("prev").disabled, true);
    assert.equal(v.lensBtn("next").disabled, false);
    v.lensBtn("next").click();
    assert.deepEqual(v.lit(), ["b.rb", "c.rb"]);
    assert.equal(v.lensBtn("next").disabled, true);
    v.lensBtn("next").click();
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 2 /, "a click past the end is dropped");
    v.lensBtn("prev").click();
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 1 /);
    v.lensBtn("session").click();
    assert.equal(v.lensBtn("turn").textContent, "turn 2");
    assert.equal(v.lensBtn("next").disabled, true);
    v.lensBtn("prev").click();
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 2 /, "from the session lens ‹ goes to the newest turn");
    v.lensBtn("session").click();
    v.lensBtn("turn").click();
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 2 /);
  } finally { v.done(); }
});

test("the chip opens the session lens even after a turn lens; the rail's open is the running turn's lens, the live turn steppable", () => {
  const v = lensView();
  try {
    v.foots[0].click();
    v.ws.popover.close();
    v.infoEl.querySelector(".ws-chip").click();
    assert.ok(v.ws.isOpen());
    assert.deepEqual([v.lit(), v.dim()], [[], []]);
    assert.equal(v.lensBtn("session").classList.contains("on"), true);
    v.ws.popover.close();
    // The running turn (ordinal 2) joins the turns the lens steps through.
    v.ws.liveItems({ gens: [{ tools: [{ ...read("lib/d.rb"), status: "ok" }] }] });
    const anchor = document.createElement("div");
    v.infoEl.append(anchor);
    v.ws.openTurn(anchor);
    assert.equal(v.pop.querySelector(".ws-lens-line").textContent, "turn 3 touched 1 · 1 new");
    assert.deepEqual(v.lit(), ["d.rb"]);
    assert.equal(v.lensBtn("next").disabled, true);
    v.lensBtn("prev").click();
    assert.deepEqual(v.lit(), ["b.rb", "c.rb"]);
  } finally { v.done(); }
});

test("a folded group keeps the rows the lens lights; the others wait inside it", () => {
  const files = Array.from({ length: 8 }, (_, i) => `lib/x/f${i}.rb`);
  const v = lensView({ files });
  try {
    v.foots[1].click();
    // Past the budget the files fold by directory: lib/x (8) is a group head, lib/c.rb its own row.
    const head = v.pop.querySelector(".ws-group-head");
    assert.ok(head, "the directory is folded");
    assert.equal(head.getAttribute("aria-expanded"), "false");
    // Turn 1 touched lib/c.rb and lib/b.rb (not in the group): the head is dim, no member shown.
    assert.equal(head.classList.contains("dim"), true);
    assert.equal(v.rows().filter((r) => r.classList.contains("member")).length, 0);
    // Turn 0 touched every file of the group: its head is lit and shows the members while folded.
    v.lensBtn("prev").click();
    const lit = v.pop.querySelector(".ws-group-head");
    assert.equal(lit.getAttribute("aria-expanded"), "false");
    assert.equal(lit.classList.contains("lit"), true);
    assert.equal(v.rows().filter((r) => r.classList.contains("member") && r.classList.contains("lit")).length, 8);
    // Session lens: folded means folded.
    v.lensBtn("session").click();
    assert.equal(v.rows().filter((r) => r.classList.contains("member")).length, 0);
  } finally { v.done(); }
});

test("a lit row's actions come from the session item: a read in turn 1 and an edit only in turn 2 still offers drop in turn 2's lens", () => {
  const sent = [];
  const v = lensView({
    files: ["lib/b.rb"], sendLine: (line) => { sent.push(line); return Promise.resolve(); },
    turn1: { gens: [{ tools: [{ ...read("lib/b.rb"), tool: "edit", status: "ok" }] }] },
  });
  try {
    // The server's snapshot (tokens set), so dropRefusal has something to say.
    v.ws.update({ items: [{ kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 12 }], at: 3 });
    v.foots[1].click();
    const row = v.rows().find((r) => r.dataset.wsId === "file:/p/lib/b.rb");
    assert.ok(row.classList.contains("lit"));
    assert.match(row.querySelector(".st").textContent, /edited/, "the turn's words: only edited");
    assert.equal(row.querySelector(".ws-step").textContent, "s1");
    const drop = row.querySelector('[data-op="drop"]');
    assert.equal(drop.disabled, false, "the session read it: the same drop as the session lens");
    v.lensBtn("session").click();
    assert.equal(v.rows()[0].querySelector('[data-op="drop"]').disabled, false);
  } finally { v.done(); }
});

test("a lit preloaded memory shows the turn's step tag (with its jump), not \"prompt\"; unlit, it says prompt", () => {
  const v = lensView({
    state: { preloadedMemories: ["style", "other"] },
    turn1: { gens: [{ tools: [{ tool: "memory_read", title: "style", status: "ok" }] }] },
  });
  try {
    v.foots[1].click();
    const tagOf = (id) => v.rows().find((r) => r.dataset.wsId === id).querySelector(".ws-step");
    assert.equal(tagOf("memory:style").textContent, "s1");
    assert.equal(tagOf("memory:style").dataset.at, "1.0.0");
    assert.equal(tagOf("memory:other").textContent, "prompt");
    v.lensBtn("session").click();
    assert.equal(tagOf("memory:style").textContent, "prompt");
  } finally { v.done(); }
});

test("a seed for the same session while the lens is on the live turn keeps the lens; the live turn coming back lights it again", () => {
  const v = lensView({ oneTurn: true });
  try {
    const live = { gens: [{ tools: [{ ...read("lib/d.rb"), status: "ok" }] }] };
    v.ws.liveItems(live);
    const anchor = document.createElement("div");
    v.infoEl.append(anchor);
    v.ws.openTurn(anchor);
    assert.deepEqual(v.lit(), ["d.rb"]);
    // A resync: the history is seeded again, the running turn not yet back.
    v.ws.seed(v.lists);
    assert.ok(v.ws.isOpen());
    assert.deepEqual([v.lit(), v.dim()], [[], []], "no such turn yet: the session is shown");
    v.ws.liveItems(live);
    v.ws.sessionChanged();
    assert.deepEqual(v.lit(), ["d.rb"], "the lens was kept");
  } finally { v.done(); }
});

test("one finished turn: its lens has both arrows disabled; the live turn ending keeps the lens on its turn", () => {
  const v = lensView({ oneTurn: true });
  try {
    v.foots[0].click();
    assert.equal(v.lensBtn("prev").disabled, true);
    assert.equal(v.lensBtn("next").disabled, true);
    v.lensBtn("session").click();
    assert.equal(v.lensBtn("prev").disabled, false, "from the session lens ‹ goes to that turn");
    v.lensBtn("prev").click();
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 1 /);
    v.ws.popover.close();
    // A running turn is the lens; it ends (hand-off): the lens stays on it.
    const live = { gens: [{ tools: [{ ...read("lib/d.rb"), status: "ok" }] }] };
    v.ws.liveItems(live);
    const anchor = document.createElement("div");
    v.infoEl.append(anchor);
    v.ws.openTurn(anchor);
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 2 /);
    v.ws.handOff(live);
    v.ws.sessionChanged();
    assert.match(v.pop.querySelector(".ws-lens-line").textContent, /^turn 2 touched 1/);
    assert.deepEqual(v.lit(), ["d.rb"]);
    assert.equal(v.lensBtn("prev").disabled, false);
    assert.equal(v.lensBtn("next").disabled, true);
  } finally { v.done(); }
});

// ── the head view (ws_sections.js): From the start · Read in this session · Conversation ──

if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

const PARTS = [
  { kind: "tools", label: "31 declared", chars: 24800, tokens: 6200 },
  { kind: "base", label: "base prompt", chars: 8400, tokens: 2100 },
  { kind: "identity", label: "identity", chars: 2400, tokens: 600, ref: "identity" },
  { kind: "notes", label: "model_notes_style", chars: 1600, tokens: 400, ref: "model_notes_style" },
  { kind: "agents", label: "AGENTS.md", chars: 13600, tokens: 3400, ref: "/p/AGENTS.md" },
];

// Two turns: turn 0 reads lib/a.rb, turn 1 reads the model note again and
// lib/c.rb. The session's prompt carries PARTS (the note among them).
function headView({ parts = PARTS, ctxTokens = 20000, ctxWindow = 128000, session = "h1" } = {}) {
  const historyEl = document.createElement("div");
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(historyEl, infoEl);
  const current = { preloadedMemories: [], mutedMemories: [], usedMemories: [], promptNotes: [{ name: "model_notes_style" }], promptParts: parts, ctxTokens, ctxWindow };
  let id = session;
  const ws = createWorkingSet({ historyEl, infoEl, state: () => current, session: () => id, sendLine: () => Promise.resolve() });
  const ok = (row) => ({ ...row, status: "ok" });
  const turn0 = itemsOfTurn({ gens: [{ tools: [ok(read("lib/a.rb"))] }] }, 0);
  const turn1 = itemsOfTurn({ gens: [{ tools: [ok(read("lib/c.rb"))] }, { tools: [ok({ tool: "memory_read", title: "model_notes_style" })] }] }, 1);
  ws.seed([{ items: turn0, prompt: "first" }, { items: turn1, prompt: "second" }]);
  ws.update({ items: [
    { kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 1000 }, { kind: "file", key: "/p/lib/c.rb", state: "live", tokens: 500 },
    { kind: "memory", key: "model_notes_style", state: "live", tokens: 400 },
  ], at: 9 });
  const foots = [footprintNode(turn0, 0), footprintNode(turn1, 1)];
  historyEl.append(...foots);
  const pop = ws.popover.pop;
  const open = () => ws.popover.open(infoEl.querySelector(".ws-chip"));
  const heads = () => [...pop.querySelectorAll(".ws-sec-head")].map((h) => h.querySelector(".t").textContent);
  const sec = (key) => pop.querySelector(`.ws-sec.${key}`);
  const names = (key) => [...sec(key).querySelectorAll(".ws-row")].map((r) => r.querySelector(".t").textContent);
  const done = () => {
    ws.popover.close(); infoEl.remove(); historyEl.remove(); pop.remove();
    for (const s of ["h1", "h2"]) localStorage.removeItem(`chi_ws_sections_folded:${s}`);
  };
  return { ws, pop, current, open, heads, sec, names, foots, done, setSession: (s) => { id = s; } };
}

test("the head view: three sections in order, the parts first with their tokens, read-only; the read section without the prompt's memories", () => {
  const v = headView();
  try {
    v.open();
    assert.deepEqual(v.heads(), ["From the start", "Read in this session"], "Conversation is a row, not a section header");
    assert.deepEqual(v.names("start"), ["tools", "base prompt", "identity", "model_notes_style", "AGENTS.md"]);
    const tools = v.sec("start").querySelector('.ws-row.part[data-ws-part^="tools"]');
    assert.equal(tools.querySelector(".st").textContent, "31 declared");
    assert.equal(tools.querySelector(".tk").textContent, "~6.2k");
    assert.equal(v.sec("start").querySelectorAll(".ws-row.part button").length, 0, "a part row has no actions, no peek");
    assert.equal(v.sec("start").querySelector(".ws-sec-head .tk").textContent, "~13k");
    // identity: its own memory row (the set has none); the note: the set's row, once in the whole list.
    assert.ok(v.sec("start").querySelector('.ws-row.memory[data-ws-id="memory:identity"]'));
    assert.equal(v.pop.querySelectorAll('[data-ws-id="memory:model_notes_style"]').length, 1);
    assert.deepEqual(v.names("read"), ["a.rb", "c.rb"]);
    assert.match(v.sec("read").querySelector(".ws-sec-head .n").textContent, /^2 held$/);
    // Conversation: 20000 − 12700 (parts) − 1500 (files) − 400 (the note's read).
    assert.equal(v.sec("talk").children.length, 1, "one element: the row, no header");
    const talk = v.sec("talk").firstElementChild;
    assert.ok(talk.classList.contains("talk") && talk.classList.contains("ws-row"));
    assert.equal(talk.querySelectorAll("button").length, 0, "nothing to fold");
    assert.equal(talk.textContent.replace(/\s+/g, " ").trim(), "Conversation· 2 turns~5.4k");
    assert.equal(talk.querySelector(".t").textContent, "Conversation");
    assert.equal(talk.querySelector(".n").textContent, "· 2 turns");
    assert.equal(talk.querySelector(".tk").textContent, "~5.4k");
    assert.ok(!talk.classList.contains("dim"));
    assert.equal(v.pop.querySelector(".ws-head-line").textContent, "in chi's head now · ~20k of 128k");
  } finally { v.done(); }
});

test("the header: no item count with parts and the context's tokens; the head line carries the size", () => {
  const v = headView();
  try {
    v.current.ctxPct = 16;
    v.open();
    const head = v.pop.querySelector(".ctx-pop-head");
    assert.ok(head.querySelector(".ctx-pop-kind") === null);
    assert.doesNotMatch(head.textContent, /item|ctx/);
    assert.ok(head.querySelector(".ws-ring"), "the ring stays");
    assert.ok(head.querySelector(".ctx-pop-close"), "the close button stays");
    assert.ok(v.pop.querySelector(".ws-size-line") === null);
    // A turn lens: its touched line, no size line.
    v.pop.querySelector('[data-ws="lens"][data-lens="turn"]').click();
    assert.equal(v.pop.querySelector(".ws-lens-line").textContent, "turn 2 touched 2 · 1 new");
    assert.ok(v.pop.querySelector(".ws-size-line") === null);
  } finally { v.done(); }
});

test("the size line: the session lens without the context's tokens (or without parts) says \"N items · ctx %\" under the header", () => {
  const v = headView({ ctxTokens: null });
  try {
    v.current.ctxPct = 16;
    v.open();
    assert.equal(v.pop.querySelector(".ws-size-line").textContent, "3 items · ctx 16 %");
    assert.ok(v.pop.querySelector(".ws-head-line") === null);
    assert.ok(v.pop.querySelector(".ctx-pop-head .ctx-pop-kind") === null, "never back in the header");
    // A change of its text redraws the open list (tokensChanged).
    let draws = 0;
    const refresh = v.ws.popover.refresh;
    v.ws.popover.refresh = (...args) => { draws += 1; return refresh(...args); };
    v.ws.tokensChanged();
    assert.equal(draws, 0);
    v.current.ctxPct = 17;
    v.ws.tokensChanged();
    assert.equal(draws, 1);
    assert.equal(v.pop.querySelector(".ws-size-line").textContent, "3 items · ctx 17 %");
    // The tokens come: the head line takes its place.
    v.current.ctxTokens = 20000;
    v.ws.tokensChanged();
    assert.equal(draws, 2);
    assert.ok(v.pop.querySelector(".ws-size-line") === null);
    assert.equal(v.pop.querySelector(".ws-head-line").textContent, "in chi's head now · ~20k of 128k");
  } finally { v.done(); }
});

test("held twice: the session lens tags the re-read prompt memory, its tokens the part's + the read's; the turn that read it gets the note", () => {
  const v = headView();
  try {
    v.open();
    const note = () => v.sec("start").querySelector('[data-ws-id="memory:model_notes_style"]');
    assert.equal(note().querySelector(".ws-twice").textContent, "held twice");
    assert.equal(note().querySelector(".tk").textContent, "~400 +400");
    assert.match(note().querySelector(".st").textContent, /^model note$/);
    assert.ok(v.sec("start").querySelector('[data-ws-id="memory:identity"] .ws-twice') === null);
    assert.ok(v.pop.querySelector(".ws-note") === null, "no note in the session lens");
    // Turn 2 (it read the note): lit, amber, the note under it; a part row dim.
    v.ws.popover.close();
    v.foots[1].click();
    assert.ok(note().classList.contains("lit"));
    assert.ok(note().classList.contains("twice"));
    assert.equal(note().nextElementSibling.textContent, "read again in this turn: already in the prompt, held twice (+400)");
    assert.equal(note().querySelector(".ws-step").textContent, "s2");
    assert.ok(v.sec("start").querySelector(".ws-row.part").classList.contains("dim"));
    assert.ok(v.sec("talk").querySelector(".ws-row.talk").classList.contains("dim"), "the conversation row is never lit");
    assert.ok(v.pop.querySelector(".ws-head-line") === null, "the turn lens has its own line");
    // Turn 1 (it didn't): no note, the row dimmed.
    v.pop.querySelector('[data-ws="lens"][data-lens="prev"]').click();
    assert.ok(v.pop.querySelector(".ws-note") === null);
    assert.ok(note().classList.contains("dim"));
  } finally { v.done(); }
});

test("section folds: per session; folded, a section shows only the rows the lens lights", () => {
  const v = headView();
  try {
    v.open();
    v.sec("start").querySelector(".ws-sec-head").click();
    assert.equal(v.sec("start").querySelector(".ws-sec-head").getAttribute("aria-expanded"), "false");
    assert.deepEqual(v.names("start"), [], "folded, the session lens lights nothing");
    v.sec("read").querySelector(".ws-sec-head").click();
    assert.deepEqual(v.names("read"), []);
    // Turn 2's lens: the folded start shows the note it read, the folded read its c.rb.
    v.ws.popover.close();
    v.foots[1].click();
    assert.deepEqual(v.names("start"), ["model_notes_style"]);
    assert.equal(v.sec("start").querySelector(".ws-note").textContent, "read again in this turn: already in the prompt, held twice (+400)");
    assert.deepEqual(v.names("read"), ["c.rb"]);
    // Kept for this session; another session's list opens unfolded.
    v.ws.popover.close();
    v.open();
    assert.deepEqual(v.names("start"), []);
    assert.equal(localStorage.getItem("chi_ws_sections_folded:h1"), '["start","read"]');
    v.ws.popover.close();
    v.setSession("h2");
    v.open();
    assert.deepEqual(v.names("start"), ["tools", "base prompt", "identity", "model_notes_style", "AGENTS.md"]);
    // Opened again: the key's list loses it.
    v.setSession("h1");
    v.ws.popover.close();
    v.open();
    v.sec("start").querySelector(".ws-sec-head").click();
    assert.equal(localStorage.getItem("chi_ws_sections_folded:h1"), '["read"]');
  } finally { v.done(); }
});

test("an older page's stored fold naming the conversation is ignored: the row shows; a toggle drops the stale key", () => {
  const v = headView();
  try {
    localStorage.setItem("chi_ws_sections_folded:h1", '["talk"]');
    v.open();
    assert.ok(v.sec("talk").querySelector(".ws-row.talk"));
    assert.ok(!v.sec("talk").classList.contains("folded"));
    v.sec("read").querySelector(".ws-sec-head").click();
    assert.equal(localStorage.getItem("chi_ws_sections_folded:h1"), '["read"]');
  } finally { v.done(); }
});

test("no parts (an old session or worker): today's list, the lens unchanged; no context tokens: no head line, no conversation row", () => {
  const v = headView({ parts: [], ctxTokens: null });
  try {
    v.open();
    assert.equal(v.pop.querySelectorAll(".ws-sec-head, .ws-sec").length, 0);
    assert.deepEqual([...v.pop.querySelectorAll(".ctx-pop-meta:not(.ws-hint)")].map((m) => m.textContent), ["3 items", "files · 2", "memories · 0 used · 1 in the prompt"]);
    assert.ok(v.pop.querySelector(".ws-head-line") === null);
    assert.equal(v.pop.querySelector(".ws-size-line").textContent, "3 items");
    v.ws.popover.close();
    v.foots[1].click();
    assert.equal(v.pop.querySelector(".ws-lens-line").textContent, "turn 2 touched 2 · 1 new");
    // Parts come (a turn end's re-read), still no context tokens: the sections, no line, no Conversation.
    v.current.promptParts = PARTS;
    v.ws.sessionChanged();
    assert.deepEqual(v.heads(), ["From the start", "Read in this session"]);
    v.pop.querySelector('[data-ws="lens"][data-lens="session"]').click();
    assert.ok(v.pop.querySelector(".ws-head-line") === null);
    // The tokens come: the line, no window: no "of Y".
    v.current.ctxTokens = 30000;
    v.current.ctxWindow = null;
    v.ws.sessionChanged();
    assert.equal(v.pop.querySelector(".ws-head-line").textContent, "in chi's head now · ~30k");
    assert.deepEqual(v.heads(), ["From the start", "Read in this session"]);
    assert.equal(v.sec("talk").querySelector(".ws-row.talk .tk").textContent, "~15k");
  } finally { v.done(); }
});

test("a turn lens never counts a prompt memory as new, even one the set doesn't hold as preloaded", () => {
  const v = headView();
  try {
    v.current.promptNotes = [];
    v.foots[1].click();
    assert.equal(v.pop.querySelector(".ws-lens-line").textContent, "turn 2 touched 2 · 1 new");
    assert.ok(v.sec("start").querySelector('[data-ws-id="memory:model_notes_style"]').classList.contains("lit"));
  } finally { v.done(); }
});

test("the context's tokens: chunks that leave the shown text alone draw nothing; a change draws the line", () => {
  const v = headView({ ctxTokens: 20000 });
  try {
    v.open();
    let draws = 0;
    const refresh = v.ws.popover.refresh;
    v.ws.popover.refresh = (...args) => { draws += 1; return refresh(...args); };
    // ~20k and the conversation's ~5.4k stay: no draw.
    for (const tokens of [20010, 20020, 20030, 20040]) {
      v.current.ctxTokens = tokens;
      v.ws.tokensChanged();
    }
    assert.equal(draws, 0);
    // The conversation's text moves (~5.5k): one draw, the row says it.
    v.current.ctxTokens = 20100;
    v.ws.tokensChanged();
    assert.equal(draws, 1);
    assert.equal(v.sec("talk").querySelector(".tk").textContent, "~5.5k");
    // The head line's (~21k): a draw, the line says it.
    v.current.ctxTokens = 21000;
    v.ws.tokensChanged();
    assert.equal(draws, 2);
    assert.equal(v.pop.querySelector(".ws-head-line").textContent, "in chi's head now · ~21k of 128k");
    // Closed: nothing.
    v.ws.popover.close();
    v.current.ctxTokens = 40000;
    v.ws.tokensChanged();
    assert.equal(draws, 2);
  } finally { v.done(); }
});
