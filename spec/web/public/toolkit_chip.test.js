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

test("chipModel: a name that didn't resolve, and the file's reading (no left_out)", () => {
  const chip = chipModel({ name: "coordinator", label: "coordinator", left_out: [], fallback: "no toolkit named coordinator" });
  assert.equal(chip.text, "tools coordinator ?");
  assert.match(chip.title, /no toolkit named coordinator: every tool is declared \(full\) until it resolves\. Nothing left out\./);
  assert.doesNotMatch(chipModel({ name: "lean", label: "lean" }).title, /Not loaded|Nothing left out/);
});
