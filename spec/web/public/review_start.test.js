import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createReviewStartControl, formatSubjects, parseSubjects, readSubjects, reviewChipModel } from "../../../lib/samagotchi/web/public/review_start.js";
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

// A path with a space can be named: in double quotes; the form shows it
// quoted again, so a second Set reads it back whole.
test("review start: a quoted path keeps its spaces and commas; the form quotes it back; an open quote is an error", () => {
  assert.deepEqual(parseSubjects('"docs/my plan.md", notes.txt "a,b.md"'), ["docs/my plan.md", "notes.txt", "a,b.md"]);
  assert.equal(formatSubjects(["docs/my plan.md", "notes.txt", "a,b.md"]), '"docs/my plan.md", notes.txt, "a,b.md"');
  assert.deepEqual(parseSubjects(formatSubjects(["docs/my plan.md", "notes.txt"])), ["docs/my plan.md", "notes.txt"]);
  assert.deepEqual(readSubjects('notes.txt "docs/my plan'), { subjects: [], error: 'A quote isn\'t closed: "docs/my plan' });
  assert.deepEqual(readSubjects('""'), { subjects: [], error: null });
});

function reviewControl() {
  const el = document.createElement("button");
  el.id = "reviewNew";
  document.body.append(el);
  let chosen = [];
  const ctl = createReviewStartControl({ el, choice: () => chosen, choose: (next) => { chosen = next; },
                                         win: { innerWidth: 1000, innerHeight: 800 } });
  const pop = [...document.querySelectorAll("#reviewNewPopover")].pop();
  const form = () => pop.querySelector("form");
  const set = (text) => {
    form().elements.subjects.value = text;
    form().dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  };
  return { el, ctl, pop, set, chosen: () => chosen, done: () => { el.remove(); pop.remove(); } };
}

test("review start: an open quote stays in the form with its error; Start's refusal opens the form with the server's words", () => {
  const c = reviewControl();
  c.el.click();
  c.set('"docs/my plan');
  assert.equal(c.pop.hidden, false);
  assert.equal(c.pop.querySelector(".ctx-pop-error").textContent, 'A quote isn\'t closed: "docs/my plan');
  assert.equal(c.pop.querySelector("textarea").value, '"docs/my plan');
  assert.deepEqual(c.chosen(), []);
  c.set('"docs/my plan.md"');
  assert.equal(c.pop.hidden, true);
  assert.deepEqual(c.chosen(), ["docs/my plan.md"]);
  c.ctl.refuse(".env can't be a review subject: it may hold secrets");
  assert.equal(c.pop.hidden, false);
  assert.equal(c.pop.querySelector(".ctx-pop-error").textContent, ".env can't be a review subject: it may hold secrets");
  assert.equal(c.pop.querySelector("textarea").value, '"docs/my plan.md"');
  assert.equal(c.pop.querySelector("textarea").getAttribute("aria-invalid"), "true");
  c.done();
});
