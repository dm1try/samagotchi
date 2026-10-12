import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { linkRefs, resolveRef, textRefs, touchedFiles } from "../../../lib/samagotchi/web/public/ref_scan.js";

const CWD = "/p";
const touched = new Set(["/p/lib/foo.rb", "/p/lib/samagotchi/source_links.rb", "/p/web/app.js", "/q/web/app.js", "/p/README.md"]);

// The text of each ref textRefs finds, with what it resolved to.
function found(text, files = touched) {
  return textRefs(text, files, CWD).map(([s, e, ref]) => [text.slice(s, e), ref.path, ref.line, ref.end_line]);
}

function mount(html) {
  const el = document.createElement("div");
  el.innerHTML = html;
  return el;
}

// LineLinker's cases (github_pr_plugin_spec.rb), against the touched files.
test("refs in inline code and in text, ranges too; fenced code, markdown links and URLs stay", () => {
  const text = [
    "`lib/foo.rb:28` and lib/foo.rb:28-30, `./lib/foo.rb:87:4`.",
    "```",
    "lib/foo.rb:28",
    "```",
    "[lib/foo.rb:28](https://x.test/a) https://x.test/lib/foo.rb:28 `see lib/foo.rb:28`",
  ].join("\n");
  assert.deepEqual(found(text), [
    ["`lib/foo.rb:28`", "/p/lib/foo.rb", 28, null],
    ["lib/foo.rb:28-30", "/p/lib/foo.rb", 28, 30],
    ["`./lib/foo.rb:87:4`", "/p/lib/foo.rb", 87, null],
  ]);
});

test("a bare name or an absolute path: the one touched file it names", () => {
  assert.deepEqual(found("source_links.rb:2 /p/lib/foo.rb:21"), [
    ["source_links.rb:2", "/p/lib/samagotchi/source_links.rb", 2, null],
    ["/p/lib/foo.rb:21", "/p/lib/foo.rb", 21, null],
  ]);
});

test("a relative path that merely ends with a touched path is another file", () => {
  assert.deepEqual(found("vendor/lib/foo.rb:21 and vendor/bundle/lib/samagotchi/source_links.rb:2"), []);
});

test("a path up from a subdir resolves to the touched file", () => {
  assert.deepEqual(found("../lib/foo.rb:21"), [["../lib/foo.rb:21", "/p/lib/foo.rb", 21, null]]);
});

test("nothing that isn't a touched file, or a path at all; line 0 never; an end line not after the line is dropped", () => {
  assert.deepEqual(found("lib/other.rb:3, example.com:443, at 10:30, bar.rb:28, lib/foo.rb:0"), []);
  assert.deepEqual(found("lib/foo.rb:9-3"), [["lib/foo.rb:9-3", "/p/lib/foo.rb", 9, null]]);
});

test("not after a backslash or a colon (a Windows path, scp's host:path); in parentheses and backticks still", () => {
  assert.deepEqual(found("C:\\x\\foo.rb:3 host:lib/foo.rb:3 see:lib/foo.rb:3"), []);
  assert.deepEqual(found("(lib/foo.rb:3) `lib/foo.rb:4`"), [
    ["lib/foo.rb:3", "/p/lib/foo.rb", 3, null],
    ["`lib/foo.rb:4`", "/p/lib/foo.rb", 4, null],
  ]);
});

test("resolveRef: exact under the cwd first, else the one touched file ending with it; ambiguous is none", () => {
  assert.equal(resolveRef("web/app.js", touched, CWD), "/p/web/app.js");
  assert.equal(resolveRef("./web/app.js", touched, CWD), "/p/web/app.js");
  assert.equal(resolveRef("app.js", touched, CWD), null);
  assert.equal(resolveRef("app.js", new Set(["/p/web/app.js"]), CWD), "/p/web/app.js");
  assert.equal(resolveRef("app.js", touched, null), null);
  assert.equal(resolveRef("/q/web/app.js", touched, CWD), "/q/web/app.js");
  assert.equal(resolveRef("/r/web/app.js", touched, CWD), null);
  assert.equal(resolveRef("/p/lib/../lib/./foo.rb", touched, CWD), "/p/lib/foo.rb");
  assert.equal(resolveRef("lib/x.rb", touched, CWD), null);
});

test("a bare path (no :line) only when it is exactly a touched file", () => {
  assert.deepEqual(found("see lib/foo.rb, README.md and foo.rb; `web/app.js` too, not app.js"), [
    ["lib/foo.rb", "/p/lib/foo.rb", null, null],
    ["README.md", "/p/README.md", null, null],
    ["`web/app.js`", "/p/web/app.js", null, null],
  ]);
  // A path ending a sentence, or before a colon in prose, is still one.
  assert.deepEqual(found("Changed lib/foo.rb: the guard."), [["lib/foo.rb", "/p/lib/foo.rb", null, null]]);
});

test("nothing is found without touched files", () => {
  assert.deepEqual(textRefs("lib/foo.rb:3", new Set(), CWD), []);
});

test("linkRefs wraps refs in a rendered answer: text and inline code alone; pre, links (below), code in a sentence stay", () => {
  const el = mount(
    "<p>See lib/foo.rb:12 and <code>lib/foo.rb:3-5</code>, not <code>cat lib/foo.rb:3</code>.</p>" +
    "<pre><code>lib/foo.rb:28\n</code></pre>" +
    '<p><a href="https://github.com/acme/app/pull/1/files#x"><code>lib/foo.rb:28</code></a> http://h:8080/lib/foo.rb:12</p>',
  );
  linkRefs(el, touched, CWD);
  const refs = [...el.querySelectorAll("span.ref")].map((r) => [r.textContent, r.dataset.refKind, r.dataset.refPath, r.dataset.refLine, r.dataset.refEndLine]);
  assert.deepEqual(refs, [
    ["lib/foo.rb:12", "file", "/p/lib/foo.rb", "12", undefined],
    ["lib/foo.rb:3-5", "file", "/p/lib/foo.rb", "3", "5"],
  ]);
  assert.equal(el.querySelector(".ref code")?.textContent, "lib/foo.rb:3-5");
  assert.equal(el.querySelector("pre .ref"), null);
  assert.equal(el.querySelector("a .ref"), null);
  assert.equal(el.querySelector("a").getAttribute("href"), "https://github.com/acme/app/pull/1/files#x");
  assert.match(el.textContent, /See lib\/foo\.rb:12 and lib\/foo\.rb:3-5, not cat lib\/foo\.rb:3\./);
});

test("linkRefs: a link whose text is a touched ref alone is that ref too (its href stays the plain click's); other links stay", () => {
  const el = mount(
    '<p><a href="https://github.com/acme/app/pull/1/files#x"><code>lib/foo.rb:28</code></a> ' +
    '<a href="https://github.com/acme/app/blob/h/lib/foo.rb#L9">lib/foo.rb:9-12</a> ' +
    '<a href="https://x.test/a">see lib/foo.rb:3</a> <a href="https://x.test/b">lib/other.rb:3</a></p>',
  );
  linkRefs(el, touched, CWD);
  linkRefs(el, touched, CWD);
  const links = [...el.querySelectorAll("a")].map((a) => [a.getAttribute("href"), a.classList.contains("ref"), a.dataset.refPath, a.dataset.refLine, a.dataset.refEndLine]);
  assert.deepEqual(links, [
    ["https://github.com/acme/app/pull/1/files#x", true, "/p/lib/foo.rb", "28", undefined],
    ["https://github.com/acme/app/blob/h/lib/foo.rb#L9", true, "/p/lib/foo.rb", "9", "12"],
    ["https://x.test/a", false, undefined, undefined, undefined],
    ["https://x.test/b", false, undefined, undefined, undefined],
  ]);
  assert.equal(el.querySelectorAll(".ref .ref, a span.ref").length, 0);
  assert.equal(el.textContent, "lib/foo.rb:28 lib/foo.rb:9-12 see lib/foo.rb:3 lib/other.rb:3");
});

test("linkRefs on a plain step text: a fenced block in the text stays; a second run wraps nothing twice", () => {
  const el = mount("");
  el.textContent = "Now I update web/app.js:40.\n```\nweb/app.js:41\n```\nthen lib/foo.rb";
  linkRefs(el, touched, CWD);
  linkRefs(el, touched, CWD);
  assert.deepEqual([...el.querySelectorAll(".ref")].map((r) => [r.textContent, r.dataset.refLine]), [
    ["web/app.js:40", "40"], ["lib/foo.rb", undefined],
  ]);
  assert.equal(el.querySelectorAll(".ref .ref").length, 0);
  assert.equal(el.textContent, "Now I update web/app.js:40.\n```\nweb/app.js:41\n```\nthen lib/foo.rb");
});

test("touchedFiles: the file refs of the rows and cards under the roots", () => {
  const rows = mount(
    '<div class="activity-row"><span class="ref" data-ref-kind="file" data-ref-path="/p/a.rb">a.rb</span></div>' +
    '<div class="bubble approval"><span class="ref" data-ref-kind="file" data-ref-path="/p/b.rb">b.rb</span></div>' +
    '<span data-ref-kind="issue" data-ref-path="x"></span>' +
    '<div class="bubble output"><span class="ref" data-ref-kind="file" data-ref-path="/p/c.rb">c.rb</span></div>',
  );
  // An answer's own file ref (a plugin's, a scanned one) isn't a touched file.
  assert.deepEqual([...touchedFiles([rows])], ["/p/a.rb", "/p/b.rb"]);
});
