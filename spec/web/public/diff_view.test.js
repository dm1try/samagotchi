import test from "node:test";
import assert from "node:assert/strict";
import { activityDiffHtml, diffCounts, diffHtml, diffLineClass, diffSummary, DIFF_FOLD_LINES } from "../../../lib/samagotchi/web/public/diff_view.js";

const diff = { text: "@@ -1,2 +1,2 @@\n a\n-b <x>\n+c & d", added: 1, removed: 1, truncated: false, new_file: false };

test("diffHtml draws each line with its kind, escaped", () => {
  assert.equal(diffHtml(diff),
    '<pre class="diff"><code>' +
    '<span class="diff-line diff-hunk">@@ -1,2 +1,2 @@</span>' +
    '<span class="diff-line diff-ctx"> a</span>' +
    '<span class="diff-line diff-del">-b &lt;x&gt;</span>' +
    '<span class="diff-line diff-add">+c &amp; d</span>' +
    "</code></pre>");
});

test("diffLineClass: hunk, add, del, the no-newline and cut notes, context", () => {
  assert.deepEqual(["@@ -1 +1 @@", "+x", "-x", "\\ No newline at end of file", "… 3 more lines", " x", ""].map(diffLineClass),
    ["hunk", "add", "del", "meta", "meta", "ctx", "ctx"]);
});

test("diffHtml folds past 20 lines behind a show-all toggle", () => {
  const text = ["@@ -0,0 +1,30 @@", ...Array.from({ length: 30 }, (_, i) => `+line ${i}`)].join("\n");
  const html = diffHtml({ text, added: 30, removed: 0, new_file: true });
  assert.equal(DIFF_FOLD_LINES, 20);
  assert.ok(html.startsWith('<div class="diff-note">new file</div><pre class="diff">'));
  assert.equal((html.split("<details")[0].match(/diff-line/g) || []).length, 20);
  assert.match(html, /<details class="diff-more"><summary>show all 31 lines<\/summary>/);
  assert.equal((html.split("<details")[1].match(/diff-line/g) || []).length, 11);
  assert.doesNotMatch(diffHtml(diff), /diff-more/);
});

test("diffHtml: an edit that would fail, a skipped file, no change, nothing", () => {
  assert.equal(diffHtml({ error: "old text not found in <f>" }), '<div class="diff-note warn">this edit would fail: old text not found in &lt;f&gt;</div>');
  assert.equal(diffHtml({ skipped: "binary file" }), '<div class="diff-note">diff not shown: binary file</div>');
  assert.equal(diffHtml({ text: "", added: 0, removed: 0 }), '<div class="diff-note">no change</div>');
  assert.equal(diffHtml(null), "");
});

test("diffSummary and diffCounts", () => {
  assert.equal(diffCounts({ added: 3, removed: 1 }), "+3 −1");
  assert.equal(diffSummary({ added: 3, removed: 1 }), "diff +3 −1");
  assert.equal(diffSummary({ added: 12, removed: 0, new_file: true }), "new file +12");
});

test("activityDiffHtml is a closed details with the summary, none for errors or skips", () => {
  assert.equal(activityDiffHtml(diff), `<details class="activity-diff"><summary>diff +1 −1</summary>${diffHtml(diff)}</details>`);
  assert.equal(activityDiffHtml({ skipped: "binary file" }), "");
  assert.equal(activityDiffHtml(undefined), "");
});
