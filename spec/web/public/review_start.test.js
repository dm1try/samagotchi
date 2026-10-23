import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { parseSubjects, reviewChipModel } from "../../../lib/samagotchi/web/public/review_start.js";
import { reviewStartedText } from "../../../lib/samagotchi/web/public/session_actions.js";

test("review start: files split on commas, spaces and lines; the chip names them", () => {
  assert.deepEqual(parseSubjects(" docs/plan.md,docs/spec.md\n docs/plan.md  notes.txt "), ["docs/plan.md", "docs/spec.md", "notes.txt"]);
  assert.deepEqual(parseSubjects(""), []);
  assert.deepEqual([reviewChipModel([]).text, reviewChipModel([]).own], ["review…", false]);
  assert.deepEqual([reviewChipModel(["docs/plan.md"]).text, reviewChipModel(["docs/plan.md"]).own], ["review: plan.md", true]);
  assert.equal(reviewChipModel(["docs/plan.md", "b.md", "c.md"]).text, "review: plan.md +2");
});

test("review start: the toast says where it starts from and that the source keeps running", () => {
  const text = reviewStartedText("3f9a1c2e-0000", { id: "4b7e9a01-1111", model_warning: null });
  assert.equal(text, "Review 4b7e9a01 started from 3f9a1c2e's recap; 3f9a1c2e keeps running. Invite someone to it.");
  assert.match(reviewStartedText("3f9a1c2e", { id: "4b7e9a01", model_warning: "x can't run" }), /\(x can't run\)/);
});
