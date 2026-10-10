import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { availableKinds, editorUrl, installRefClicks, refAction, refAttrs, refTarget, setRefKinds } from "../../../lib/samagotchi/web/public/refs.js";
import { toolRowHtml } from "../../../lib/samagotchi/web/public/turn_html.js";
import { diffHtml } from "../../../lib/samagotchi/web/public/diff_view.js";

const VSCODE = "vscode://file{path}:{line}";
const viewer = { editor: true, editorUrl: VSCODE };

function mount(html) {
  const root = document.createElement("div");
  root.innerHTML = html;
  document.body.append(root);
  return root;
}

const editRow = {
  key: "1:1", tool: "edit", title: "lib/a.rb", params: 'path="lib/a.rb"', status: "ok", output: "[edit]\nok",
  ref: { kind: "file", path: "/p/lib/a.rb" },
  diff: { text: "@@ -10,3 +10,3 @@\n a\n-b\n+c\n d", added: 1, removed: 1 },
};

test("refAttrs: the kind and the target, no action words", () => {
  assert.equal(refAttrs({ kind: "file", path: "/p/a \"b\".rb", line: 3, end_line: 9 }),
    ' data-ref-kind="file" data-ref-path="/p/a &quot;b&quot;.rb" data-ref-line="3" data-ref-end-line="9"');
  assert.equal(refAttrs({ kind: "file", path: "/p/a.rb" }), ' data-ref-kind="file" data-ref-path="/p/a.rb"');
  assert.equal(refAttrs(null), "");
  assert.equal(refAttrs({ path: "/p/a.rb" }), "");
});

test("editorUrl encodes each path segment (spaces, #, unicode), keeps the slashes, line 1 by default", () => {
  assert.equal(editorUrl(VSCODE, "/Users/me/my dir/a#1.rb", 12), "vscode://file/Users/me/my%20dir/a%231.rb:12");
  assert.equal(editorUrl(VSCODE, "/p/café/ü.md"), "vscode://file/p/caf%C3%A9/%C3%BC.md:1");
  assert.equal(editorUrl("idea://open?file={path}", "/p/a.rb", 4), "idea://open?file=/p/a.rb");
  assert.equal(editorUrl("", "/p/a.rb", 1), "");
  assert.equal(editorUrl(VSCODE, "", 1), "");
});

test("refAction: the editor is the file kind's action only for a viewer with an editor and its URL", () => {
  assert.equal(refAction("file", viewer).id, "editor");
  assert.equal(refAction("file", { editor: false, editorUrl: null }), null);
  assert.equal(refAction("file", { editor: true, editorUrl: null }), null);
  assert.equal(refAction("issue", viewer), null);
  assert.deepEqual(availableKinds(viewer), ["file"]);
  assert.deepEqual(availableKinds({}), []);
});

test("refTarget: a row title opens its file at its line, else at the first change; a diff line at its line", () => {
  const root = mount(toolRowHtml(editRow));
  const title = root.querySelector(".activity-params");
  assert.ok(title.classList.contains("ref"));
  const target = refTarget(title);
  assert.deepEqual({ kind: target.kind, path: target.path, line: target.line }, { kind: "file", path: "/p/lib/a.rb", line: 11 });
  const add = root.querySelector(".diff-line.diff-add");
  assert.equal(refTarget(add).line, 11);
  assert.equal(refTarget(root.querySelector(".diff-line.diff-hunk")).line, 10);
  assert.equal(refTarget(root.querySelector(".activity-tool")), null);

  const read = mount(toolRowHtml({ ...editRow, key: "1:2", tool: "read", diff: null, ref: { kind: "file", path: "/p/b.rb", line: 40, end_line: 60 } }));
  assert.equal(refTarget(read.querySelector(".activity-params")).line, 40);
  root.remove();
  read.remove();
});

test("refTarget: a diff line outside a row (an approval card) and a row without a ref are none", () => {
  const card = mount(`<div class="bubble question approval">${diffHtml(editRow.diff)}</div>`);
  assert.equal(refTarget(card.querySelector(".diff-line.diff-add")), null);
  const plain = mount(toolRowHtml({ ...editRow, ref: null }));
  assert.equal(plain.querySelector("[data-ref-kind]"), null);
  assert.equal(refTarget(plain.querySelector(".diff-line.diff-add")), null);
  card.remove();
  plain.remove();
});

test("installRefClicks opens the first available action's URL; none without an editor or while selecting in the row", () => {
  const root = mount(toolRowHtml(editRow));
  const opened = [];
  let current = viewer;
  let selection = null;
  installRefClicks(root, () => current, { open: (url) => opened.push(url), selection: () => selection });
  const click = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0 }));

  click(root.querySelector(".activity-params"));
  click(root.querySelector(".diff-line.diff-del"));
  assert.deepEqual(opened, ["vscode://file/p/lib/a.rb:11", "vscode://file/p/lib/a.rb:11"]);

  // A drag that selected text in the row isn't a click; a selection
  // elsewhere doesn't stop it.
  selection = { isCollapsed: false, anchorNode: root.querySelector(".activity-output").firstChild, focusNode: null };
  click(root.querySelector(".activity-params"));
  assert.equal(opened.length, 2);
  selection = { isCollapsed: false, anchorNode: document.createTextNode("x"), focusNode: null };
  click(root.querySelector(".activity-params"));
  assert.equal(opened.length, 3);
  selection = null;

  current = { editor: false, editorUrl: null };
  click(root.querySelector(".activity-params"));
  assert.equal(opened.length, 3);
  root.remove();
});

test("setRefKinds marks the kinds this viewer has an action for", () => {
  const body = document.createElement("div");
  setRefKinds(body, viewer);
  assert.ok(body.classList.contains("refs-file"));
  setRefKinds(body, { editor: false });
  assert.ok(!body.classList.contains("refs-file"));
});

test("the hover hint follows the viewer on each hover, keeping the element's own title", () => {
  const root = mount(toolRowHtml({ ...editRow, view: null }));
  let current = viewer;
  installRefClicks(root, () => current, { open: () => {} });
  const hover = (el) => el.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  const title = root.querySelector(".activity-params");
  const own = title.getAttribute("title");
  const add = root.querySelector(".diff-line.diff-add");

  hover(title);
  hover(add);
  assert.equal(title.getAttribute("title"), `${own}\nOpen the current file in your editor at line 11`);
  assert.equal(add.getAttribute("title"), "Open the current file in your editor at line 11");

  current = { editor: false, editorUrl: null };
  hover(title);
  hover(add);
  assert.equal(title.getAttribute("title"), own);
  assert.equal(add.getAttribute("title"), null);

  current = viewer;
  hover(add);
  assert.equal(add.getAttribute("title"), "Open the current file in your editor at line 11");
  root.remove();
});
