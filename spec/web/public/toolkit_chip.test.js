import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { chipModel, chipTemplate } from "../../../lib/samagotchi/web/public/toolkit_chip.js";
import { markupOf } from "./dom_shim.js";

const CHANGE = "/toolkit lists them; /toolkit NAME, add TOOL or remove TOOL changes them from the next turn.";

test("chipModel: on the default kit (full unless set) 🧰 alone, its tooltip naming the kit as the default", () => {
  assert.deepEqual(chipModel(null, "full"), { text: "", isDefault: true,
    title: `Toolkit: full (the default), every tool is declared. ${CHANGE}` });
  assert.deepEqual(chipModel(null), chipModel(null, "full"));
  // A lean default: a session on lean is on the default, one on full isn't.
  const lean = chipModel({ name: "lean", label: "lean", left_out: ["delegate"], fallback: null }, "lean");
  assert.equal(lean.text, "");
  assert.equal(lean.isDefault, true);
  assert.equal(lean.title, `Toolkit: lean (the default), the tools this session declares. Not loaded: delegate. ${CHANGE}`);
  assert.deepEqual(chipModel(null, "lean"), { text: "full", isDefault: false,
    title: `Toolkit: full, every tool is declared (the default is lean). ${CHANGE}` });
  // The default's name with tools of the session's own added is another kit.
  assert.equal(chipModel({ name: "lean", label: "lean +delegate", left_out: [] }, "lean").text, "lean +delegate");
});

test("chipTemplate: 🧰 alone on the default, 🧰 and the kit on another; nothing without the model", () => {
  assert.match(markupOf(chipTemplate({ summary: null, defaultKit: "full" })), /^<span class="model tools-chip default" title="Toolkit: full \(the default\)[^"]*"><span class="chip-icon tc-kit" aria-hidden="true">🧰<\/span><\/span>$/);
  assert.match(markupOf(chipTemplate({ summary: { name: "lean", label: "lean" }, defaultKit: "full" })),
    /^<span class="model tools-chip" title="Toolkit: lean, the tools[^"]*"><span class="chip-icon tc-kit" aria-hidden="true">🧰<\/span> lean<\/span>$/);
  assert.equal(markupOf(chipTemplate(null)), "");
});

test("chipModel: the label, and what it leaves out in the tooltip", () => {
  const chip = chipModel({ name: "lean", label: "lean +delegate", left_out: ["send_note", "list_sessions"], fallback: null });
  assert.equal(chip.text, "lean +delegate");
  assert.equal(chip.title, "Toolkit: lean +delegate, the tools this session declares. Not loaded: send_note, list_sessions. " +
    "/toolkit lists them; /toolkit NAME, add TOOL or remove TOOL changes them from the next turn.");
});

test("chipModel: what find_tools reaches and what the toolkit removes", () => {
  const chip = chipModel({ name: "child", label: "child", left_out: ["list_sessions", "memory_write"],
    reachable: ["list_sessions"], removed: ["memory_write"], fallback: null });
  assert.equal(chip.title, "Toolkit: child, the tools this session declares. Reachable with find_tools: list_sessions. " +
    "Removed: memory_write. /toolkit lists them; /toolkit NAME, add TOOL or remove TOOL changes them from the next turn.");
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean", left_out: ["delegate"], reachable: ["delegate"], removed: [] }).title,
    /Removed|Not loaded/);
});

test("chipModel: source-group scope appears in the tooltip", () => {
  const chip = chipModel({ name: "coding", label: "coding", groups: [], left_out: [], reachable: [], removed: [] });
  assert.match(chip.title, /Source groups: none\./);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean", groups: "all", left_out: [] }).title, /Source groups/);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean", groups: ":all", left_out: [] }).title, /Source groups/);
});

test("chipModel: a kit's prompt text ends the tooltip, only when the summary has one", () => {
  const chip = chipModel({ name: "coding", label: "coding", left_out: [], reachable: [], removed: [], fallback: null,
    prompt: "- Be concise in your responses" });
  assert.match(chip.title, /changes them from the next turn\. Prompt: - Be concise in your responses$/);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean", left_out: [] }).title, /Prompt:/);
});

test("chipModel: a name that didn't resolve, and the file's reading (no left_out)", () => {
  const chip = chipModel({ name: "coordinator", label: "coordinator", left_out: [], fallback: "no toolkit named coordinator" });
  assert.equal(chip.text, "coordinator ?");
  assert.match(chip.title, /no toolkit named coordinator: every tool is declared \(full\) until it resolves\. Nothing left out\./);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean" }).title, /Not loaded|Nothing left out/);
});
