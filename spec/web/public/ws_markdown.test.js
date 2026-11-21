import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  RENDER_MAX_BYTES, createRenderCache, peekText, renderable, renderableEvent, sourceText, splitFrontMatter,
} from "../../../lib/samagotchi/web/public/ws_markdown.js";

const tick = () => new Promise((r) => setTimeout(r, 0));
const read = (first, last, { whole = false, partial = false, text = "# T\n" } = {}) => ({ op: "read", lines: { first, last, whole, partial }, text });
const slice = (first, reads, rows = [{ n: 1, text: "# Title" }, { n: 2, text: "body" }]) => ({ type: "slice", first, last: first + rows.length - 1, reads, rows });
const mdItem = { kind: "file", key: "/p/docs/README.md" };

test("renderable: a memory read and a memory write; a whole read of an .md or .markdown file (any case)", () => {
  assert.equal(renderable({ type: "memory", event: { op: "memory_read", text: "x" } }, { kind: "memory", key: "style" }), true);
  assert.equal(renderable({ type: "written", event: { op: "memory_write", text: "x" } }, { kind: "memory", key: "style" }), true);
  assert.equal(renderable(slice(1, [read(1, 2, { whole: true })]), mdItem), true);
  assert.equal(renderable(slice(1, [read(1, 2, { whole: true })]), { kind: "file", key: "/p/NOTES.Markdown" }), true);
  assert.equal(renderable(slice(1, [read(1, 2, { whole: true })]), { kind: "file", key: "/p/README.MD" }), true);
});

test("renderable: a slice that isn't the whole file, another file, an edit, a partial read, a fetch: no", () => {
  assert.equal(renderable(slice(40, [read(40, 41)]), mdItem), false, "a slice from line 40");
  assert.equal(renderable(slice(1, [read(1, 2)]), mdItem), false, "from line 1 but no whole read");
  assert.equal(renderable(slice(1, [read(1, 2, { whole: true })]), { kind: "file", key: "/p/a.rb" }), false);
  assert.equal(renderable(slice(1, [read(1, 2, { whole: true })]), { kind: "file", key: "/p/md" }), false);
  assert.equal(renderable({ type: "edit", event: { op: "edit" } }, mdItem), false);
  assert.equal(renderable({ type: "partial", event: read(1, 2, { whole: true, partial: true }) }, mdItem), false);
  assert.equal(renderable({ type: "fetch", event: { op: "fetch", text: "# x" } }, { kind: "url", key: "https://x.test/a.md" }), false);
  assert.equal(renderable(null, mdItem), false);
});

test("renderableEvent: the peek's rule on an event", () => {
  assert.equal(renderableEvent({ op: "memory_read", text: "x" }, { kind: "memory", key: "style" }), true);
  assert.equal(renderableEvent({ op: "memory_write", text: "x" }, { kind: "memory", key: "style" }), true);
  assert.equal(renderableEvent(read(1, 9, { whole: true }), mdItem), true);
  assert.equal(renderableEvent(read(1, 9, { whole: true, partial: true }), mdItem), false, "a preview of the file");
  assert.equal(renderableEvent(read(3, 9), mdItem), false, "a slice");
  assert.equal(renderableEvent(read(1, 9, { whole: true }), { kind: "file", key: "/p/a.rb" }), false);
  assert.equal(renderableEvent({ op: "edit" }, mdItem), false);
  assert.equal(renderableEvent({ op: "fetch", text: "# x" }, { kind: "url", key: "https://x.test/a.md" }), false);
});

test("sourceText: a slice's rows joined, an event's text", () => {
  assert.equal(sourceText(slice(1, [])), "# Title\nbody");
  assert.equal(sourceText({ type: "memory", event: { text: "be brief\n" } }), "be brief\n");
  assert.equal(sourceText({ type: "memory", event: {} }), "");
});

test("splitFrontMatter: a leading --- block closed by --- is the front; anything else is all body", () => {
  assert.deepEqual(splitFrontMatter("---\nname: x\ntype: y\n---\n# T\nbody\n"), { front: "---\nname: x\ntype: y\n---", body: "# T\nbody\n" });
  assert.deepEqual(splitFrontMatter("---\nname: x\n---"), { front: "---\nname: x\n---", body: "" });
  assert.deepEqual(splitFrontMatter("---\r\nname: x\r\n---\r\nbody"), { front: "---\r\nname: x\r\n---", body: "body" });
  assert.deepEqual(splitFrontMatter("# T\n---\nname: x\n---\n"), { front: "", body: "# T\n---\nname: x\n---\n" }, "not at the start");
  assert.deepEqual(splitFrontMatter("---\nnever closed\n"), { front: "", body: "---\nnever closed\n" });
  assert.deepEqual(splitFrontMatter("a\n\n---\n\nb"), { front: "", body: "a\n\n---\n\nb" }, "a rule mid-text (several memories) stays");
  assert.deepEqual(splitFrontMatter(null), { front: "", body: "" });
});

test("peekText: front matter is removed, but text without front matter is unchanged", () => {
  assert.equal(peekText("---\nname: style\n---\n# Style\nbe brief\n"), "# Style\nbe brief\n");
  assert.equal(peekText("# Style\nbe brief\n"), "# Style\nbe brief\n");
  assert.equal(peekText("a\n\n---\n\nb"), "a\n\n---\n\nb");
});

test("the cache: one request per text, undefined while it is on its way, then the HTML and onReady", async () => {
  const asked = [];
  let ready = 0;
  const cache = createRenderCache((text) => { asked.push(text); return Promise.resolve(`<p>${text}</p>`); }, () => { ready += 1; });
  assert.equal(cache.html("a"), undefined);
  assert.equal(cache.html("a"), undefined, "still pending: not asked again");
  assert.deepEqual(asked, ["a"]);
  await tick();
  assert.equal(ready, 1);
  assert.equal(cache.html("a"), "<p>a</p>");
  assert.deepEqual(asked, ["a"], "kept");
});

test("the cache: a null (markdown off, a failed read) is not kept, and calls no onReady; the next draw asks again", async () => {
  let answer = null;
  const asked = [];
  let ready = 0;
  const cache = createRenderCache((text) => { asked.push(text); return Promise.resolve(answer); }, () => { ready += 1; });
  assert.equal(cache.html("a"), undefined);
  await tick();
  assert.equal(ready, 0, "nothing to redraw: the source stays");
  answer = "<p>a</p>";
  assert.equal(cache.html("a"), undefined, "asked again");
  await tick();
  assert.equal(cache.html("a"), "<p>a</p>");
  assert.equal(asked.length, 2);
  assert.equal(ready, 1);
});

test("the cache: a rejected request is a null", async () => {
  let ready = 0;
  const cache = createRenderCache(() => Promise.reject(new Error("x")), () => { ready += 1; });
  assert.equal(cache.html("a"), undefined);
  await tick();
  assert.equal(ready, 0);
});

test("the cache: a text whose JSON body is over the route's cap is null, without a request", () => {
  const asked = [];
  const cache = createRenderCache((text) => { asked.push(text); return Promise.resolve("<p></p>"); }, () => {});
  assert.equal(RENDER_MAX_BYTES, 64 * 1024);
  // 22,000 three-byte characters: under the cap in characters, over it in bytes.
  assert.equal(cache.html("あ".repeat(22000)), null);
  assert.equal(cache.html("a".repeat(70000)), null);
  assert.deepEqual(asked, []);
});

test("the cache is bounded: the oldest text goes first", async () => {
  const asked = [];
  const cache = createRenderCache((text) => { asked.push(text); return Promise.resolve(`<p>${text}</p>`); }, () => {}, { max: 2 });
  cache.html("a");
  cache.html("b");
  await tick();
  cache.html("a");
  cache.html("c");
  await tick();
  assert.equal(cache.html("a"), "<p>a</p>", "a was used last: kept");
  assert.equal(cache.html("b"), undefined, "b went: asked again");
  assert.deepEqual(asked, ["a", "b", "c", "b"]);
});
