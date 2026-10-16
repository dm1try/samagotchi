import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { chipModel } from "../../../lib/samagotchi/web/public/toolkit_chip.js";

test("chipModel: nothing on full (no summary)", () => {
  assert.equal(chipModel(null), null);
});

test("chipModel: the label, and what it leaves out in the tooltip", () => {
  const chip = chipModel({ name: "lean", label: "lean +delegate", left_out: ["send_note", "list_sessions"], fallback: null });
  assert.equal(chip.text, "tools lean +delegate");
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

test("chipModel: a kit's prompt text ends the tooltip, only when the summary has one", () => {
  const chip = chipModel({ name: "coding", label: "coding", left_out: [], reachable: [], removed: [], fallback: null,
    prompt: "- Be concise in your responses" });
  assert.match(chip.title, /changes them from the next turn\. Prompt: - Be concise in your responses$/);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean", left_out: [] }).title, /Prompt:/);
});

test("chipModel: a name that didn't resolve, and the file's reading (no left_out)", () => {
  const chip = chipModel({ name: "coordinator", label: "coordinator", left_out: [], fallback: "no toolkit named coordinator" });
  assert.equal(chip.text, "tools coordinator ?");
  assert.match(chip.title, /no toolkit named coordinator: every tool is declared \(full\) until it resolves\. Nothing left out\./);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean" }).title, /Not loaded|Nothing left out/);
});
