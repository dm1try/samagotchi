import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { footprintNode, groupItems, stampHistory, stampRows } from "../../../lib/samagotchi/web/public/working_set_view.js";
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
