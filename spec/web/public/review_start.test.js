import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { formatSubjects, readSubjects, reviewChipModel } from "../../../lib/samagotchi/web/public/review_start.js";
import { reviewStartedText } from "../../../lib/samagotchi/web/public/session_actions.js";

test("review start: files split on commas, spaces and lines; the chip names them", () => {
  assert.deepEqual(readSubjects(" docs/plan.md,docs/spec.md\n docs/plan.md  notes.txt ").subjects, ["docs/plan.md", "docs/spec.md", "notes.txt"]);
  assert.deepEqual(readSubjects("").subjects, []);
  assert.deepEqual([reviewChipModel([]).text, reviewChipModel([]).own], ["review…", false]);
  assert.deepEqual([reviewChipModel(["docs/plan.md"]).text, reviewChipModel(["docs/plan.md"]).own], ["review: plan.md", true]);
  assert.equal(reviewChipModel(["docs/plan.md", "b.md", "c.md"]).text, "review: plan.md +2");
});

test("review start: the toast says where it starts from and that the source keeps running", () => {
  const text = reviewStartedText("3f9a1c2e-0000", { id: "4b7e9a01-1111", model_warning: null });
  assert.equal(text, "Review 4b7e9a01 started from 3f9a1c2e's recap; 3f9a1c2e keeps running. Invite someone to it.");
  assert.match(reviewStartedText("3f9a1c2e", { id: "4b7e9a01", model_warning: "x can't run" }), /\(x can't run\)/);
});

// A path with a space can be named: in double quotes; the form shows it
// quoted again, so a second Set reads it back whole.
test("review start: a quoted path keeps its spaces and commas; the form quotes it back; an open quote is an error", () => {
  assert.deepEqual(readSubjects('"docs/my plan.md", notes.txt "a,b.md"').subjects, ["docs/my plan.md", "notes.txt", "a,b.md"]);
  assert.equal(formatSubjects(["docs/my plan.md", "notes.txt", "a,b.md"]), '"docs/my plan.md", notes.txt, "a,b.md"');
  assert.deepEqual(readSubjects(formatSubjects(["docs/my plan.md", "notes.txt"])).subjects, ["docs/my plan.md", "notes.txt"]);
  assert.deepEqual(readSubjects('notes.txt "docs/my plan'), { subjects: [], error: 'A quote isn\'t closed: "docs/my plan' });
  assert.deepEqual(readSubjects('""'), { subjects: [], error: null });
});
