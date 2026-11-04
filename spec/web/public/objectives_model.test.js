import test from "node:test";
import assert from "node:assert/strict";
import { addLine, changeText, editableText, entryLine, headline, markLine, pendingText, progress, rewordLine, stripItems } from "../../../lib/samagotchi/web/public/objectives_model.js";

const list = { items: [
  { id: "O1", text: "A", status: "done" }, { id: "O2", text: "B", status: "active" },
  { id: "O3", text: "C", status: "dropped" }, { id: "O4", text: "D", status: "active" },
] };

test("the strip shows active first, then done, and no dropped one", () => {
  assert.deepEqual(stripItems(list).map((i) => i.id), ["O2", "O4", "O1"]);
  assert.deepEqual(stripItems(null), []);
});

test("progress counts only what is still meant", () => {
  assert.deepEqual(progress(list), { done: 1, total: 3 });
});

test("the headline is the first active, else the last done, else nothing", () => {
  assert.equal(headline(list).id, "O2");
  assert.equal(headline({ items: [{ id: "O1", text: "A", status: "done" }] }).id, "O1");
  assert.equal(headline({ items: [{ id: "O1", text: "A", status: "dropped" }] }), null);
});

test("an entry says what the user changed, or nothing for a first list", () => {
  assert.equal(entryLine({ items: [] }), null);
  assert.equal(entryLine({ changes: [] }), null);
  assert.equal(entryLine({ changes: [{ id: "O2", kind: "done", text: "B" }, { id: "O5", kind: "added", text: "E" }] }),
    "You marked O2 done · added O5 E");
  assert.equal(changeText({ id: "O3", kind: "reworded", text: "New", was: "Old" }), "reworded O3: Old → New");
  assert.equal(changeText({ id: "O3", kind: "dropped", text: "x" }), "dropped O3 x");
  assert.equal(changeText({ id: "O3", kind: "reopened", text: "x" }), "reopened O3");
});

test("the edit lines are /objectives lines, one line each", () => {
  assert.equal(markLine("done", "O2"), "/objectives done O2");
  assert.equal(addLine("  two\nlines "), "/objectives add two lines");
  assert.equal(addLine("  "), null);
  assert.equal(rewordLine("O2", "new text"), "/objectives edit O2 new text");
  assert.equal(rewordLine("O2", " "), null);
});

test("the edit box shows the form the command reads back", () => {
  assert.equal(editableText({ text: "A" }), "A");
  assert.equal(editableText({ text: "A", done_when: "b" }), "A (done when: b)");
});

test("a waiting edit says so, mid-turn that it waits for the turn", () => {
  assert.equal(pendingText({ pending: false }, true), null);
  assert.equal(pendingText({ pending: true }, true), "Applies after this turn");
  assert.equal(pendingText({ pending: true }, false), null);
});
