import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readLines, readLinesTemplate } from "../../../lib/samagotchi/web/public/read_view.js";

const readLinesHtml = (row) => markupOf(readLinesTemplate(row));

const ref = { kind: "file", path: "/p/a.rb" };
const row = (output, extra = {}) => ({ key: "1:1", tool: "read", status: "ok", title: "a.rb", ref, output, ...extra });
const pairs = (lines) => lines.map(({ text, line }) => [text, line]);

test("readLines numbers the file as-is: only \"[read]\\n\" goes, leading blank lines and indentation stay", () => {
  assert.deepEqual(pairs(readLines(row("[read]\n\n  def a\n\tb\nend\n"))),
    [["", 1], ["  def a", 2], ["\tb", 3], ["end", 4]]);
  // A file without a last newline, and a file whose last line is blank.
  assert.deepEqual(pairs(readLines(row("[read]\na\nb"))), [["a", 1], ["b", 2]]);
  assert.deepEqual(pairs(readLines(row("[read]\na\n\n"))), [["a", 1], ["", 2]]);
});

test("readLines starts a range read at its start_line (the ref's line)", () => {
  assert.deepEqual(pairs(readLines(row("[read]\nx\ny\n", { ref: { ...ref, line: 40, end_line: 41 } }))), [["x", 40], ["y", 41]]);
});

test("readLines drops the gate's ran-as line before the tag", () => {
  assert.deepEqual(pairs(readLines(row('ran as: read path="/p/a.rb"\n[read]\nx\n'))), [["x", 1]]);
});

test("readLines numbers nothing after a cut, the clamped-range note or an omitted marker; the newline before one is its own", () => {
  assert.deepEqual(pairs(readLines(row("[read]\na\nb\n[cut: 4 of 99 chars; read it in parts]"))),
    [["a", 1], ["b", 2], ["[cut: 4 of 99 chars; read it in parts]", null]]);
  assert.deepEqual(pairs(readLines(row("[read]\na\n\n[cut: 2 of 99 chars; read it in parts]"))),
    [["a", 1], ["[cut: 2 of 99 chars; read it in parts]", null]]);
  const clamped = "[read]\nx\ny\n\n[read: end_line 9 exceeds 4 lines; returning lines 3-4]";
  assert.deepEqual(pairs(readLines(row(clamped, { ref: { ...ref, line: 3, end_line: 9 } }))),
    [["x", 3], ["y", 4], ["[read: end_line 9 exceeds 4 lines; returning lines 3-4]", null]]);
  assert.deepEqual(pairs(readLines(row("[read]\na\n[... omitted 5 bytes ...]\nb"))),
    [["a", 1], ["[... omitted 5 bytes ...]", null], ["b", null]]);
});

test("readLines: a marker-looking line in the file itself (not in the last two lines) is a line like any other", () => {
  const log = "[read]\n[cut: 3 of 9 chars; read it in parts]\n[... omitted 5 bytes ...]\n[read: end_line 9 exceeds 4 lines; x]\nend\nlast\n";
  assert.deepEqual(pairs(readLines(row(log))), [
    ["[cut: 3 of 9 chars; read it in parts]", 1], ["[... omitted 5 bytes ...]", 2], ["[read: end_line 9 exceeds 4 lines; x]", 3],
    ["end", 4], ["last", 5],
  ]);
  // The clamped-range note, then ToolRunner's cut after it: both are markers.
  assert.deepEqual(pairs(readLines(row("[read]\na\n\n[read: end_line 9 exceeds 1 lines; returning lines 1-1]\n[cut: 9 of 99 chars; read it in parts]"))),
    [["a", 1], ["[read: end_line 9 exceeds 1 lines; returning lines 1-1]", null], ["[cut: 9 of 99 chars; read it in parts]", null]]);
});

test("readLines numbers a reload's capped output up to the cap, then says more is not shown", () => {
  assert.deepEqual(pairs(readLines(row("[read]\na\nbb", { output_truncated: true }))), [["a", 1], ["bb", 2], ["…", null]]);
  // A live cut read is output_truncated too: its cut line says it, no "…".
  assert.deepEqual(pairs(readLines(row("[read]\na\n[cut: 2 of 9 chars; read it in parts]", { output_truncated: true }))),
    [["a", 1], ["[cut: 2 of 9 chars; read it in parts]", null]]);
});

test("readLines: none for the head/tail preview, an error, an image, a row without a ref, another tool or a running row", () => {
  const preview = "[read]\ntruncated=true\npath=/p/a.rb\npreview_strategy=head_tail\n\n[TRUNCATED_PREVIEW_HEAD]\na";
  assert.equal(readLines(row(preview)), null);
  assert.equal(readLines(row("[read]\nError: file not found: /p/a.rb", { status: "error" })), null);
  assert.equal(readLines(row("[read]\nError: start_line must be <= end_line")), null);
  assert.equal(readLines(row("[read] Error: blocked by guardrail: no", { status: "blocked" })), null);
  assert.equal(readLines(row("[read]\nImage a.png (2×2 PNG) attached.", { images: [{ file: "x.png" }] })), null);
  assert.equal(readLines(row("[read]\na.png (2×2 PNG) is an image; this model can't see images")), null);
  assert.equal(readLines(row("[read]\na.png (PNG) is not attached: at most 4 images per tool result")), null);
  assert.equal(readLines(row("[read]\nx", { ref: null })), null);
  assert.equal(readLines(row("[edit]\nx", { tool: "edit" })), null);
  assert.equal(readLines(row("", { status: "running" })), null);
  assert.equal(readLines(row("[read]\n")), null);
  assert.equal(readLines(row("[read] x")), null);
});

test("readLinesTemplate: a closed toggle naming the lines, each numbered line with its data-line", () => {
  assert.equal(readLinesHtml(row("[read]\n<a>\nb\n[cut: 4 of 9 chars; read it in parts]", { ref: { ...ref, line: 7 } })),
    '<details class="activity-read"><summary>lines 7–8</summary><pre class="read-lines"><code>' +
    '<span class="read-line" data-line="7">&lt;a&gt;</span><span class="read-line" data-line="8">b</span>' +
    '<span class="read-line read-meta">[cut: 4 of 9 chars; read it in parts]</span></code></pre></details>');
  assert.match(readLinesHtml(row("[read]\nx")), /<summary>line 1<\/summary>/);
  assert.equal(readLinesHtml(row("[read]\nError: no")), "");
});

test("readLinesTemplate draws a blank line of the file as a <br>, not a space", () => {
  const html = readLinesHtml(row("[read]\n\nx\n\ny\n"));
  assert.match(html, /<summary>lines 1–4<\/summary>/);
  assert.match(html, /<span class="read-line" data-line="1"><br><\/span><span class="read-line" data-line="2">x<\/span>/);
  assert.match(html, /<span class="read-line" data-line="3"><br><\/span><span class="read-line" data-line="4">y<\/span>/);
});
