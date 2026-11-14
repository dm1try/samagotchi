import test from "node:test";
import assert from "node:assert/strict";
import {
  bandBox, countsText, eventState, eventTag, fileStrip, itemPath, linesText, peekOf, readRows, timelineCards,
} from "../../../lib/samagotchi/web/public/ws_timeline.js";

const text = (first, last) => `${Array.from({ length: last - first + 1 }, (_, i) => `line ${first + i}`).join("\n")}\n`;
const read = (id, first, last, extra = {}) => ({
  tool_id: id, op: "read", step: Number(id.slice(1)), sent: true, dropped: false, forgotten: false,
  lines: { first, last, whole: false, partial: false }, text: text(first, last), ...extra,
});
const edit = (id, diff = { text: "@@ -1,1 +1,1 @@\n-a\n+b", added: 1, removed: 1 }) => ({
  tool_id: id, op: "edit", step: Number(id.slice(1)), sent: true, dropped: false, forgotten: false, diff,
});

test("readRows numbers a read's lines from its first, up to its last", () => {
  assert.deepEqual(readRows(read("t1", 5, 6)), [{ n: 5, text: "line 5" }, { n: 6, text: "line 6" }]);
  assert.deepEqual(readRows({ op: "read", lines: { first: 1, last: 1 }, text: "a\nb\n" }), [{ n: 1, text: "a" }]);
});

test("overlapping and touching reads merge into one slice, each line from the newest read", () => {
  const newer = read("t3", 10, 20, { text: text(10, 20).replace("line 15", "line 15 changed") });
  const cards = timelineCards([read("t1", 1, 12), read("t2", 30, 40), newer, read("t4", 21, 25)]);

  assert.deepEqual(cards.map((c) => [c.type, c.first, c.last]), [["slice", 1, 25, undefined], ["slice", 30, 40, undefined]].map(([t, f, l]) => [t, f, l]));
  assert.deepEqual(cards[0].reads.map((r) => r.tool_id), ["t4", "t3", "t1"]);
  assert.equal(cards[0].rows.find((r) => r.n === 15).text, "line 15 changed");
  assert.equal(cards[0].rows.length, 25);
  assert.equal(cards[0].latest, true);
  assert.equal(cards[1].latest, undefined);
});

test("reads in another state never merge: a forgotten or dropped slice is its own, greyed", () => {
  const cards = timelineCards([
    read("t1", 1, 50, { sent: false, forgotten: true }), read("t2", 40, 60), read("t3", 55, 70, { sent: false, dropped: true }),
  ]);

  assert.deepEqual(cards.map((c) => [c.first, c.last, c.state]), [[55, 70, "dropped"], [40, 60, "sent"], [1, 50, "forgotten"]]);
});

test("edits, partial reads, memory reads and fetches are cards of their own, newest first", () => {
  const partial = { tool_id: "t2", op: "read", sent: true, lines: { first: null, last: null, whole: true, partial: true }, text: "truncated=true" };
  const cards = timelineCards([read("t1", 1, 5), partial, edit("t3"), { tool_id: "t4", op: "fetch", sent: true, text: "page" }]);

  assert.deepEqual(cards.map((c) => c.type), ["fetch", "edit", "partial", "slice"]);
});

test("the file strip: merged bands (per version) over the largest last line, the newest read's band latest", () => {
  const strip = fileStrip([read("t1", 1, 40), read("t2", 60, 160, { sent: false, forgotten: true }), read("t3", 204, 693), edit("t4"), read("t5", 204, 265)]);

  assert.equal(strip.length, 693);
  assert.deepEqual(strip.bands, [
    { first: 1, last: 40, state: "sent" }, { first: 204, last: 693, state: "sent" }, { first: 60, last: 160, state: "forgotten" },
    // After the edit: a band of its own (another version of the file).
    { first: 204, last: 265, state: "sent" }, { first: 204, last: 265, state: "sent", latest: true },
  ]);
  assert.deepEqual(bandBox({ first: 1, last: 40 }, 693), { left: "0.00%", width: "5.77%" });
  assert.equal(fileStrip([edit("t1")]), null);
});

test("the peek: the latest edit's diff and what came after it, else the newest read's first lines", () => {
  const withEdit = peekOf([read("t1", 1, 40), edit("t2"), read("t3", 236, 250)]);
  assert.equal(withEdit.kind, "diff");
  assert.equal(withEdit.event.tool_id, "t2");
  assert.equal(withEdit.after.tool_id, "t3");

  const reads = peekOf([read("t1", 1, 40)]);
  assert.equal(reads.kind, "lines");
  assert.equal(reads.rows.length, 12);
  assert.equal(peekOf([]), null);
  // A no-op edit (no diff) shows the read.
  assert.equal(peekOf([read("t1", 1, 2), edit("t2", null)]).kind, "lines");
});

test("counts, tags and words", () => {
  assert.equal(countsText([read("t1", 1, 2), read("t2", 3, 4), edit("t3")]), "2 reads, 1 edit");
  const item = { runs: [{ id: "t1", at: { turn: 2, step: 13, row: 0 } }] };
  assert.equal(eventTag(read("t1", 1, 2), item), "t3·s14");
  assert.equal(eventTag(read("t9", 1, 2), item), "step 9");
  assert.equal(linesText({ first: 3, last: 3 }), "line 3");
  assert.equal(linesText({ first: 1, last: null, whole: true, partial: true }), "a preview of the file");
  assert.equal(eventState({ sent: false, dropped: true }), "dropped");
  assert.equal(itemPath("s 1", "file", "/a b.rb", { now: true }), "/api/sessions/s%201/working_set/item?kind=file&key=%2Fa+b.rb&now=1");
});

test("an edit starts a new merge group: reads of two versions of the file never merge", () => {
  const v1 = { tool_id: "t1", op: "read", sent: true, lines: { first: 1, last: 4, whole: false, partial: false }, text: "a\nb\nc\nd\n" };
  const ins = { tool_id: "t2", op: "edit", sent: true, diff: { text: "@@ -1,2 +1,3 @@\n a\n+NEW\n b", added: 1, removed: 0 } };
  const v2 = { tool_id: "t3", op: "read", sent: true, lines: { first: 3, last: 6, whole: false, partial: false }, text: "b\nc\nd\ne\n" };
  const cards = timelineCards([v1, ins, v2]);

  assert.deepEqual(cards.map((c) => [c.type, c.first, c.last]), [["slice", 3, 6], ["edit", undefined, undefined], ["slice", 1, 4]]);
  assert.deepEqual(cards[0].rows.map((r) => `${r.n}:${r.text}`), ["3:b", "4:c", "5:d", "6:e"]);
  assert.deepEqual(cards[2].rows.map((r) => `${r.n}:${r.text}`), ["1:a", "2:b", "3:c", "4:d"]);
  assert.equal(cards[1].event.diff.text.includes("+NEW"), true);
});
