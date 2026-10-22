import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorkingSet, footprintNode, groupItems, stampHistory, stampRows } from "../../../lib/samagotchi/web/public/working_set_view.js";
import { itemsOfTurn } from "../../../lib/samagotchi/web/public/working_set.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_view.js";
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
  // The turn view (and the flag off): no stamps, no footprint.
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
  // An empty set: no chip at all, and no mem chip either.
  renderInfoBar(div, bar({ workingSet: { chip: null } }));
  assert.equal(div.querySelectorAll(".ws-chip, .mem-chip").length, 0);
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

  // A newer one where it is live again: the strike goes.
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 90 }], at: 8 });
  assert.equal(foot.querySelector(".l.forgotten"), null);
  assert.equal(foot.querySelector(".f"), null);
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

// Steering (P3a): a view whose list is open, the lines it posts recorded.
function steeringView({ wide = true } = {}) {
  const infoEl = document.createElement("div");
  infoEl.innerHTML = '<button class="ws-chip"></button>';
  document.body.append(infoEl);
  const sent = [];
  const win = { innerWidth: wide ? 1200 : 390, innerHeight: 800 };
  const ws = createWorkingSet({
    historyEl: document.createElement("div"), infoEl, session: () => "s1",
    state: () => ({ preloadedMemories: [], mutedMemories: [], usedMemories: [] }),
    sendLine: (line) => { sent.push(line); return Promise.resolve(); },
  });
  const turn = itemsOfTurn({ gens: [{ tools: [{ ...read("lib/a.rb"), status: "ok" }, { ...read("lib/b.rb"), status: "ok" }] }] }, 0);
  ws.seed([{ items: turn, prompt: "first" }]);
  ws.update({ items: [{ kind: "file", key: "/p/lib/a.rb", state: "live", tokens: 40 }, { kind: "file", key: "/p/lib/b.rb", state: "live", tokens: 9 }], at: 4 });
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

test("pending ops come from command_queued (any client's), net with their inverse, clear at command_ran; undo and undo all", () => {
  const { ws, pop, sent, row, infoEl } = steeringView();
  ws.commandQueued({ command_id: "c1", line: "/working-set drop /p/lib/a.rb /p/lib/b.rb", waits: "turn_end", client_id: "other" });
  ws.commandQueued({ command_id: "c0", line: "/model x", waits: "turn_end" });
  const a = row("a.rb");
  assert.ok(a.classList.contains("pending"));
  assert.equal(a.querySelector(".ws-pend").textContent, "drops next turn");
  assert.match(pop.querySelector(".ws-pending").textContent, /^2 changes pending · apply at the next turn's start · undo all/);
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
