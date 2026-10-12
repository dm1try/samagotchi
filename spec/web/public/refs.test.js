import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { bindRef, editorUrl, httpUrl, installRefClicks, refActions, refAttrs, refTarget, showInTurn, syncRefTabs, turnRowFor } from "../../../lib/samagotchi/web/public/refs.js";
import { createRefMenu } from "../../../lib/samagotchi/web/public/ref_menu.js";
import { linkRefs, touchedFiles } from "../../../lib/samagotchi/web/public/ref_scan.js";
import { pairAnswerRefs, setAnswerRefs } from "../../../lib/samagotchi/web/public/answer_refs.js";
import { toolRowHtml } from "../../../lib/samagotchi/web/public/turn_html.js";
import { diffHtml } from "../../../lib/samagotchi/web/public/diff_view.js";
import { createQuestionCards } from "../../../lib/samagotchi/web/public/question_cards.js";

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

// An edit's approval card as the page draws it (question_cards.js).
function approvalCard(approval) {
  const root = mount("");
  const cards = createQuestionCards({
    sessionId: () => "s1", clientId: "web", place: (card) => root.append(card), isNearBottom: () => false,
    scrollToEnd: () => {}, removeHintIfEmpty: () => {}, api: {},
  });
  cards.renderQuestion({ id: "a1", kind: "approval", question: "Edit?", options: ["Allow", "Deny"], approval });
  return root;
}

test("refTarget: an approval card's path opens the current file at the dry run's first change; its diff lines at theirs", () => {
  const root = approvalCard({ tool: "edit", paths: ["/p/lib/a.rb"], reason: "r", preview: editRow.diff });
  const path = root.querySelector(".approval-what .ref");
  const target = refTarget(path);
  assert.deepEqual({ kind: target.kind, path: target.path, line: target.line }, { kind: "file", path: "/p/lib/a.rb", line: 11 });
  assert.ok(target.owner.matches(".bubble.approval"));
  assert.equal(refTarget(root.querySelector(".approval-diff .diff-line.diff-add")).line, 11);
  assert.equal(refTarget(root.querySelector(".approval-diff .diff-line.diff-hunk")).line, 10);
  assert.equal(refTarget(root.querySelector(".approval-tool")), null);

  const opened = [];
  installRefClicks(root, () => viewer, { open: (url) => opened.push(url), selection: () => null });
  path.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0 }));
  root.querySelector(".approval-diff .diff-line.diff-hunk").dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0 }));
  assert.deepEqual(opened, ["vscode://file/p/lib/a.rb:11", "vscode://file/p/lib/a.rb:10"]);
  root.remove();
});

test("refTarget: a write approval without a diff opens at line 1; a command approval has no ref", () => {
  const write = approvalCard({ tool: "write", paths: ["/p/new.rb", "/p/two.rb"], reason: "r" });
  const [first, second] = write.querySelectorAll(".approval-what .ref");
  assert.equal(refTarget(first).line, null);
  assert.equal(refTarget(second).path, "/p/two.rb");
  const command = approvalCard({ tool: "execute", command: "cat /p/a.rb", paths: ["/p/a.rb"], reason: "r" });
  assert.equal(command.querySelector("[data-ref-kind]"), null);
  write.remove();
  command.remove();
});

test("refTarget: a diff line outside a row or a card, and a row without a ref, are none", () => {
  const loose = mount(`<div class="bubble">${diffHtml(editRow.diff)}</div>`);
  assert.equal(refTarget(loose.querySelector(".diff-line.diff-add")), null);
  const card = mount(`<div class="bubble question approval">${diffHtml(editRow.diff)}</div>`);
  assert.equal(refTarget(card.querySelector(".diff-line.diff-add")), null);
  const plain = mount(toolRowHtml({ ...editRow, ref: null }));
  assert.equal(plain.querySelector("[data-ref-kind]"), null);
  assert.equal(refTarget(plain.querySelector(".diff-line.diff-add")), null);
  loose.remove();
  card.remove();
  plain.remove();
});

test("refTarget: a read row's numbered line opens the file at that line; an unnumbered one is none", () => {
  const root = mount(toolRowHtml({
    key: "1:3", tool: "read", status: "ok", title: "b.rb", ref: { kind: "file", path: "/p/b.rb", line: 40, end_line: 41 },
    output: "[read]\nx\ny\n[cut: 4 of 9 chars; read it in parts]",
  }));
  const [x, y, cut] = root.querySelectorAll(".activity-read .read-line");
  assert.equal(refTarget(y).line, 41);
  assert.equal(refTarget(cut), null);
  const opened = [];
  installRefClicks(root, () => viewer, { open: (url) => opened.push(url), selection: () => null });
  x.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0 }));
  assert.deepEqual(opened, ["vscode://file/p/b.rb:40"]);
  root.remove();
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

// P4: a ref's targets and its menu.
const PHONE = { editor: false, editorUrl: null };
const ids = (actions) => actions.map((action) => action.id);
const click = (el) => el.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
const key = (el, k) => el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
const tap = (el) => {
  el.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true, pointerType: "touch" }));
  click(el);
};

// A turn as the page draws it: the steps (closed) holding a read row and
// an edit row of lib/a.rb, then the answer naming it, as text and as
// github-pr's PR diff link.
function turnPage() {
  const readRow = toolRowHtml({
    key: "1:1", tool: "read", status: "ok", title: "lib/a.rb", ref: { kind: "file", path: "/p/lib/a.rb", line: 1, end_line: 2 },
    output: "[read]\nx\ny",
  });
  const root = mount(
    `<details class="turn-work"><summary>steps</summary><details class="gen"><summary>step</summary>${readRow}${toolRowHtml(editRow)}</details></details>` +
    '<div class="bubble output markdown"><p>Fixed at lib/a.rb:11, see <a href="https://github.com/acme/app/pull/4/files#diff-1R11"><code>lib/a.rb:11</code></a>; read lib/a.rb:2.</p></div>',
  );
  linkRefs(root.querySelector(".bubble.output"), touchedFiles([root]), "/p");
  const [readEl, editEl] = root.querySelectorAll(".activity-row");
  const [text, link, readRef] = root.querySelectorAll(".bubble.output .ref");
  return { root, readRow: readEl, editRow: editEl, text, link, readRef };
}

function cleanup(...roots) {
  for (const el of [...roots, ...document.querySelectorAll(".ref-menu, .ref-more")]) el.remove();
}

test("refActions: the targets per ref, with and without an editor", () => {
  const page = turnPage();
  const title = page.editRow.querySelector(".activity-params");
  // A row's own title: no "show in turn" (it would show itself).
  assert.deepEqual(ids(refActions(refTarget(title), viewer)), ["editor", "copy"]);
  assert.deepEqual(ids(refActions(refTarget(title), PHONE)), []);
  // An answer's ref: the row that touched it, on a phone too.
  assert.deepEqual(ids(refActions(refTarget(page.text), viewer)), ["editor", "show", "copy"]);
  assert.deepEqual(ids(refActions(refTarget(page.text), PHONE)), ["show", "copy"]);
  // github-pr's link: the PR diff first, its plain click.
  assert.deepEqual(ids(refActions(refTarget(page.link), viewer)), ["link", "editor", "show", "copy"]);
  assert.deepEqual(ids(refActions(refTarget(page.link), PHONE)), ["link", "show", "copy"]);
  assert.deepEqual(refActions(refTarget(page.link), viewer).map((a) => a.label(refTarget(page.link))), ["PR diff", "Open in editor", "Show in turn", "Copy path"]);
  // A diff or read line: its click only.
  assert.deepEqual(ids(refActions(refTarget(page.editRow.querySelector(".diff-line.diff-add")), viewer)), ["editor"]);
  assert.deepEqual(ids(refActions(refTarget(page.readRow.querySelector(".read-line")), viewer)), ["editor"]);
  assert.deepEqual(ids(refActions(refTarget(page.readRow.querySelector(".read-line")), PHONE)), []);
  assert.deepEqual(refActions(null, viewer), []);
  cleanup(page.root);
});

test("refActions: an approval card's path shows the row that touched the file only when there is one", () => {
  const card = approvalCard({ tool: "edit", paths: ["/p/lib/a.rb"], reason: "r", preview: editRow.diff });
  const path = card.querySelector(".approval-what .ref");
  assert.deepEqual(ids(refActions(refTarget(path), viewer)), ["editor", "copy"]);
  assert.deepEqual(ids(refActions(refTarget(path), PHONE)), []);
  const rows = mount(toolRowHtml({ ...editRow, key: "1:9" }));
  assert.deepEqual(ids(refActions(refTarget(path), PHONE)), ["show", "copy"]);
  assert.deepEqual(ids(refActions(refTarget(card.querySelector(".approval-diff .diff-line.diff-add")), PHONE)), []);
  cleanup(card, rows);
});

test("turnRowFor: the last row before the ref showing its line, else the last before it, never the ref's own", () => {
  const page = turnPage();
  assert.equal(turnRowFor(refTarget(page.text)), page.editRow);
  assert.equal(turnRowFor(refTarget(page.readRef)), page.readRow);
  assert.equal(turnRowFor({ ...refTarget(page.text), line: 99 }), page.editRow);
  assert.equal(turnRowFor({ ...refTarget(page.text), path: "/p/other.rb" }), null);
  assert.equal(turnRowFor(refTarget(page.editRow.querySelector(".activity-params"))), page.readRow);
  cleanup(page.root);
});

test("showInTurn opens the steps, the row's diff at the line, scrolls to it and flashes the row and the line", () => {
  const page = turnPage();
  const scrolled = [];
  const revealed = [];
  page.root.addEventListener("ref:reveal", (e) => revealed.push(e.target));
  window.HTMLElement.prototype.scrollIntoView = function (options) { scrolled.push([this, options]); };
  const row = showInTurn(refTarget(page.text), { behavior: "auto" });
  assert.equal(row, page.editRow);
  // The stage opens its cloud on the row's ref:reveal.
  assert.deepEqual(revealed, [page.editRow]);
  assert.ok(page.root.querySelector(".turn-work").open);
  assert.ok(page.root.querySelector("details.gen").open);
  assert.ok(page.editRow.querySelector(".activity-diff").open);
  const line = page.editRow.querySelector('.diff-line.diff-add[data-line="11"]');
  assert.deepEqual(scrolled, [[line, { block: "center", behavior: "auto" }]]);
  assert.ok(row.classList.contains("ref-flash"));
  assert.ok(line.classList.contains("ref-flash"));
  // A read line: its read opens.
  showInTurn(refTarget(page.readRef), { behavior: "auto" });
  assert.ok(page.readRow.querySelector(".activity-read").open);
  assert.equal(scrolled.at(-1)[0], page.readRow.querySelector('.read-line[data-line="2"]'));
  assert.equal(showInTurn({ ...refTarget(page.text), path: "/p/none.rb" }), null);
  delete window.HTMLElement.prototype.scrollIntoView;
  cleanup(page.root);
});

function installed(root, current) {
  const calls = [];
  installRefClicks(root, () => current(), {
    open: (url) => calls.push(["open", url]), openLink: (href) => calls.push(["link", href]),
    show: (target) => calls.push(["show", target.path, target.line]), copy: (text) => calls.push(["copy", text]),
    selection: () => null,
  });
  return calls;
}

test("a plain click runs the main target: the editor, else show in turn; a link's click is the browser's", () => {
  const page = turnPage();
  let current = viewer;
  const calls = installed(page.root, () => current);
  click(page.text);
  current = PHONE;
  click(page.text);
  click(page.editRow.querySelector(".activity-params"));
  assert.deepEqual(calls, [["open", "vscode://file/p/lib/a.rb:11"], ["show", "/p/lib/a.rb", 11]]);
  current = viewer;
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 });
  page.link.querySelector("code").dispatchEvent(event);
  assert.equal(event.defaultPrevented, false);
  assert.equal(calls.length, 2);
  cleanup(page.root);
});

test("a tap opens the menu of the ref's targets; picking one runs it; a tap on a line is its click", () => {
  const page = turnPage();
  let current = PHONE;
  const calls = installed(page.root, () => current);
  page.link.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true, pointerType: "touch" }));
  page.link.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  assert.equal(document.querySelector(".ref-more"), null);
  click(page.link);
  const menu = document.querySelector(".ref-menu");
  assert.deepEqual([...menu.querySelectorAll('[role="menuitem"]')].map((b) => b.textContent), ["PR diff", "Show in turn", "Copy path"]);
  assert.equal(page.link.getAttribute("aria-expanded"), "true");
  click(menu.querySelector('[data-target="show"]'));
  assert.equal(document.querySelector(".ref-menu"), null);
  assert.deepEqual(calls, [["show", "/p/lib/a.rb", 11]]);
  tap(page.text);
  click(document.querySelector('.ref-menu [data-target="copy"]'));
  tap(page.link);
  click(document.querySelector('.ref-menu [data-target="link"]'));
  assert.deepEqual(calls.slice(1), [["copy", "/p/lib/a.rb"], ["link", "https://github.com/acme/app/pull/4/files#diff-1R11"]]);
  current = viewer;
  tap(page.editRow.querySelector(".diff-line.diff-add"));
  assert.equal(document.querySelector(".ref-menu"), null);
  assert.deepEqual(calls.at(-1), ["open", "vscode://file/p/lib/a.rb:11"]);
  cleanup(page.root);
});

test("keyboard: Enter is the main target, ↓ opens the menu on its first target, ↑/↓ move, Esc closes back to the ref", () => {
  const page = turnPage();
  const calls = installed(page.root, () => viewer);
  key(page.root, "Tab"); // the tab stops, worked out before the focus moves
  page.text.focus();
  assert.equal(document.activeElement, page.text);
  key(page.text, "Enter");
  assert.deepEqual(calls, [["open", "vscode://file/p/lib/a.rb:11"]]);
  key(page.text, "ArrowDown");
  const items = [...document.querySelectorAll('.ref-menu [role="menuitem"]')];
  assert.deepEqual(items.map((b) => b.dataset.target), ["editor", "show", "copy"]);
  assert.equal(document.activeElement, items[0]);
  key(items[0], "ArrowDown");
  assert.equal(document.activeElement, items[1]);
  key(items[1], "ArrowUp");
  key(items[0], "ArrowUp");
  assert.equal(document.activeElement, items[2]);
  key(items[2], "Escape");
  assert.equal(document.querySelector(".ref-menu"), null);
  assert.equal(document.activeElement, page.text);
  // A link's Enter is its own click (the browser's); ↓ still opens its menu.
  const enter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
  page.link.dispatchEvent(enter);
  assert.equal(enter.defaultPrevented, false);
  key(page.link, "ArrowDown");
  assert.equal(document.querySelector('.ref-menu [role="menuitem"]').dataset.target, "link");
  cleanup(page.root);
});

test("hover: the ▾ shows on a ref with more than one target and opens its menu; not on a line or a ref with one", () => {
  const page = turnPage();
  installed(page.root, () => PHONE);
  const hover = (el) => el.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  hover(page.text);
  assert.equal(page.text.dataset.refMain, "show");
  assert.equal(page.text.getAttribute("title"), "Show the row that touched it in the turn");
  const more = document.querySelector(".ref-more");
  assert.equal(more.hidden, false);
  click(more);
  assert.deepEqual([...document.querySelectorAll('.ref-menu [role="menuitem"]')].map((b) => b.dataset.target), ["show", "copy"]);
  const title = page.editRow.querySelector(".activity-params");
  createRefMenu(document); // another page's menu doesn't meddle
  hover(title);
  assert.equal(title.dataset.refMain, undefined);
  cleanup(page.root);
});

test("the ▾ sits in room its ref makes after itself, which it gives back when it moves or hides", () => {
  const page = turnPage();
  const menu = createRefMenu(document);
  menu.showMore(page.text, () => {});
  const more = document.querySelector(".ref-more");
  assert.equal(page.text.dataset.refMore, "");
  const title = page.editRow.querySelector(".activity-params");
  menu.showMore(title, () => {});
  assert.equal(page.text.dataset.refMore, undefined);
  assert.equal(title.dataset.refMore, "");
  menu.hideMore();
  assert.equal(title.dataset.refMore, undefined);
  assert.equal(more.hidden, true);
  cleanup(page.root);
});

// The room would wrap a ref that ends its line (layout stubbed: its last
// box drops a line while it has the room): it makes none, and the ▾ goes
// past its end instead of into the room.
test("a ref the room would push onto the next line makes none: the ▾ goes past its end", () => {
  const page = turnPage();
  const menu = createRefMenu(document);
  const box = (el, wraps) => {
    el.getClientRects = () => {
      const down = wraps && el.dataset.refMore === "";
      return [{ top: down ? 120 : 100, height: 20, right: down ? 40 : (el.dataset.refMore === "" ? 219 : 200), left: 0 }];
    };
  };
  box(page.text, true);
  menu.showMore(page.text, () => {});
  const more = document.querySelector(".ref-more");
  assert.equal(page.text.dataset.refMore, "end");
  assert.equal(more.style.left, "202px");
  // Shown again for the same ref (the pointer came back): kept as it is.
  menu.showMore(page.text, () => {});
  assert.equal(page.text.dataset.refMore, "end");

  box(page.link, false);
  menu.showMore(page.link, () => {});
  assert.equal(page.text.dataset.refMore, undefined);
  assert.equal(page.link.dataset.refMore, "");
  assert.equal(more.style.left, `${219 - (more.offsetWidth || 16) - 1}px`);
  cleanup(page.root);
});

// Rows by the steps they sit in: +rows+ ({path, line}) as edit rows with a
// diff at their line.
function stepHtml(text, rows) {
  const items = rows.map(({ key, path, line }) => toolRowHtml({
    key, tool: "edit", title: path.split("/").pop(), status: "ok", output: "[edit]\nok", ref: { kind: "file", path },
    diff: { text: `@@ -${line},1 +${line},1 @@\n-a\n+b`, added: 1, removed: 1 },
  })).join("");
  return `<details class="gen"><summary>s</summary><div class="gen-text">${text}</div><div class="activity-body">${items}</div></details>`;
}
const turnHtml = (prompt, steps, answer) =>
  `<div class="bubble user">${prompt}</div><details class="turn-work"><summary>steps</summary>${steps.join("")}</details>` +
  `<div class="bubble output">${answer}</div>`;
const rowKey = (row) => row?.dataset.key;
const textRef = (root, sel) => {
  for (const el of root.querySelectorAll(sel)) linkRefs(el, touchedFiles([root]), "/p");
};

test("turnRowFor: a step's text ref takes its own step's row, after the text, over an earlier step's", () => {
  const root = mount(turnHtml("go", [
    stepHtml("Reading it.", [{ key: "1:1", path: "/p/web/app.js", line: 40 }]),
    stepHtml("Now I update web/app.js:40.", [{ key: "1:2", path: "/p/web/app.js", line: 40 }]),
  ], "Done."));
  textRef(root, ".gen-text");
  const ref = root.querySelectorAll(".gen-text .ref")[0];
  assert.equal(ref.closest(".gen").querySelector(".activity-row").dataset.key, "1:2");
  assert.equal(rowKey(turnRowFor(refTarget(ref))), "1:2");
  cleanup(root);
});

test("turnRowFor: a stage answer's ref takes the stage's own rows (the cloud after it), not an earlier turn's", () => {
  const history = mount(turnHtml("one", [stepHtml("x", [{ key: "1:1", path: "/p/lib/a.rb", line: 3 }])], "First."));
  const stage = mount(
    '<section class="turn-stage"><div class="ts-answer"><div class="bubble output">Fixed lib/a.rb:3.</div></div>' +
    `<div class="ts-cloud"><div class="ts-cloud-body"><details class="turn-work"><summary>s</summary>${stepHtml("y", [{ key: "2:1", path: "/p/lib/a.rb", line: 3 }])}</details></div></div></section>`,
  );
  linkRefs(stage.querySelector(".bubble.output"), touchedFiles([history, stage]), "/p");
  assert.equal(rowKey(turnRowFor(refTarget(stage.querySelector(".ts-answer .ref")))), "2:1");
  cleanup(history, stage);
});

test("turnRowFor: an answer's ref takes its own turn's row; a later turn never wins over an earlier one, and with neither the nearest", () => {
  const root = mount(
    turnHtml("one", [stepHtml("x", [{ key: "1:1", path: "/p/lib/a.rb", line: 3 }, { key: "1:2", path: "/p/lib/b.rb", line: 1 }])], "First: lib/a.rb:3.") +
    turnHtml("two", [stepHtml("y", [{ key: "2:1", path: "/p/lib/a.rb", line: 3 }])], "Second: lib/a.rb:9 and lib/b.rb:1.") +
    turnHtml("three", [stepHtml("z", [{ key: "3:1", path: "/p/lib/c.rb", line: 1 }])], "Third: lib/c.rb:1.") +
    turnHtml("four", [stepHtml("w", [{ key: "4:1", path: "/p/lib/c.rb", line: 1 }])], "Fourth."),
  );
  textRef(root, ".bubble.output");
  const [first, second] = root.querySelectorAll(".bubble.output");
  assert.equal(rowKey(turnRowFor(refTarget(first.querySelector(".ref")))), "1:1");
  const [a9, b1] = second.querySelectorAll(".ref");
  assert.equal(rowKey(turnRowFor(refTarget(a9))), "2:1");
  // Not in its turn: the last row before it.
  assert.equal(rowKey(turnRowFor(refTarget(b1))), "1:2");
  // A ref above every row of its file: the nearest after it, not the last.
  const lone = mount('<div class="bubble output">See lib/c.rb:1.</div>');
  root.prepend(lone);
  textRef(lone, ".bubble.output");
  linkRefs(lone.querySelector(".bubble.output"), touchedFiles([root]), "/p");
  assert.equal(rowKey(turnRowFor(refTarget(lone.querySelector(".ref")))), "3:1");
  cleanup(root);
});

test("syncRefTabs: a ref is a tab stop (a button, with a menu when it has more targets) only while it has a target", () => {
  const page = turnPage();
  const title = page.editRow.querySelector(".activity-params");
  syncRefTabs(page.root, PHONE);
  assert.equal(title.getAttribute("tabindex"), null);
  assert.equal(title.getAttribute("role"), null);
  assert.equal(page.text.getAttribute("tabindex"), "0");
  assert.equal(page.text.getAttribute("role"), "button");
  assert.equal(page.text.getAttribute("aria-haspopup"), "menu");
  // A link keeps its own role and focus; it says it has a menu.
  assert.equal(page.link.getAttribute("role"), null);
  assert.equal(page.link.getAttribute("tabindex"), null);
  assert.equal(page.link.getAttribute("aria-haspopup"), "menu");
  syncRefTabs(page.root, viewer);
  assert.equal(title.getAttribute("tabindex"), "0");
  assert.equal(title.getAttribute("aria-haspopup"), "menu");
  // A Tab press works them out for the viewer of the moment.
  let current = viewer;
  installed(page.root, () => current);
  current = PHONE;
  key(page.root, "Tab");
  assert.equal(title.getAttribute("tabindex"), null);
  cleanup(page.root);
});

test("after a tap, Enter on a focused link is the link's own click, not the menu", () => {
  const page = turnPage();
  installed(page.root, () => PHONE);
  tap(page.text);
  document.querySelector(".ref-menu")?.remove();
  key(page.link, "Enter"); // a keyboard press: the pointer is a keyboard now
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 });
  page.link.dispatchEvent(event);
  assert.equal(event.defaultPrevented, false);
  assert.equal(document.querySelector(".ref-menu"), null);
  cleanup(page.root);
});

// P5a: a ref as data (the server's Ref: {kind, target, label?, actions:
// [{id, label, url}]}) bound to its element, the plugins' actions next to
// the kind's own.
const PR = "https://github.com/acme/app/pull/4/files#diff-1R11";
const JIRA = "https://jira.test/browse/ABC-12";

test("httpUrl: an http(s) URL as the page would open it, anything else none", () => {
  assert.equal(httpUrl(" https://x.test/a?b=1#c "), "https://x.test/a?b=1#c");
  assert.equal(httpUrl("http://x.test"), "http://x.test/");
  for (const url of ["javascript:alert(1)", "JavaScript:alert(1)", "vscode://file/p:1", "data:text/html,x", "mailto:a@b.test", "/relative", "", null, 7]) {
    assert.equal(httpUrl(url), null, String(url));
  }
});

test("httpUrl: no userinfo, a host, at most 2,000 characters (trimmed), as the server's RefAction.http_url?", () => {
  for (const url of ["https://github.com@evil.example/x", "https://u:p@h.test/", "https://:p@h.test/", "https://u@h.test/"]) {
    assert.equal(httpUrl(url), null, url);
  }
  const base = "https://x.test/";
  const at2000 = base + "a".repeat(2000 - base.length);
  assert.equal(httpUrl(at2000), at2000);
  assert.equal(httpUrl(` ${at2000} `), at2000);
  assert.equal(httpUrl(at2000 + "a"), null);
});

test("bindRef drops a userinfo action; a userinfo href doesn't take an action's label", () => {
  const root = mount(`<p><span>ABC-12</span> <a href="https://jira.test@evil.test/browse/ABC-12">ABC-12</a></p>`);
  const [span, link] = root.querySelectorAll("span, a");
  const actions = [{ id: "open", label: "Open in Jira", url: JIRA }, { id: "evil", label: "Evil", url: "https://jira.test@evil.test/browse/ABC-12" }];
  bindRef(span, { kind: "issue", target: { id: "ABC-12" }, actions });
  assert.deepEqual(refTarget(span).actions, [{ id: "open", label: "Open in Jira", url: JIRA }]);
  bindRef(link, { kind: "issue", target: { id: "ABC-12" }, actions });
  // The link's href isn't an http URL the page opens: no LINK target, the action stays a menu item.
  const target = refTarget(link);
  const found = refActions(target, viewer);
  assert.ok(!found.some((action) => action.id === "link" && action.label(target) === "Evil"));
  assert.deepEqual(found.filter((a) => a.id !== "link").map((a) => a.id), ["url:open"]);
  cleanup(root);
});

test("bindRef: the element carries the kind and the target as a ref does; the data (label, actions) lives off the DOM", () => {
  const root = mount('<p>see <span>lib/a.rb:11</span> and <span>ABC-12</span></p>');
  const [file, issue] = root.querySelectorAll("span");
  bindRef(file, { kind: "file", target: { path: "/p/lib/a.rb", line: 11 }, actions: [{ id: "pr_diff", label: "PR diff", url: PR }] });
  bindRef(issue, {
    kind: "issue", target: { id: "ABC-12" }, label: "ABC-12 Login fails",
    actions: [{ id: "open", label: "Open in Jira", url: JIRA }, { id: "bad", label: "Bad", url: "javascript:alert(1)" }, { id: "nolabel", url: JIRA + "/x" }],
  });
  assert.ok(file.classList.contains("ref"));
  assert.equal(file.dataset.refKind, "file");
  assert.equal(file.dataset.refPath, "/p/lib/a.rb");
  assert.equal(file.dataset.refLine, "11");
  assert.equal(issue.dataset.refKind, "issue");
  // No JSON on the element: the actions are the WeakMap's.
  assert.doesNotMatch(root.innerHTML, /jira|github|Open in/);
  const target = refTarget(file);
  assert.deepEqual({ kind: target.kind, path: target.path, line: target.line, el: target.el }, { kind: "file", path: "/p/lib/a.rb", line: 11, el: file });
  assert.deepEqual(target.actions, [{ id: "pr_diff", label: "PR diff", url: PR }]);
  // A bad URL, or an action without a label, is dropped.
  const other = refTarget(issue);
  assert.deepEqual({ kind: other.kind, id: other.id, label: other.label }, { kind: "issue", id: "ABC-12", label: "ABC-12 Login fails" });
  assert.deepEqual(other.actions, [{ id: "open", label: "Open in Jira", url: JIRA }]);
  // A ref without data (a row title, a scanned ref) has none.
  const row = mount(toolRowHtml(editRow));
  assert.deepEqual(refTarget(row.querySelector(".activity-params")).actions, []);
  assert.equal(bindRef(null, { kind: "file" }), null);
  cleanup(root, row);
});

test("refActions: a file ref's plugin actions come after the editor, for every viewer; the kind's own stay", () => {
  const page = turnPage();
  bindRef(page.text, { kind: "file", target: { path: "/p/lib/a.rb", line: 11 }, actions: [{ id: "pr_diff", label: "PR diff", url: PR }, { id: "blob", label: "File at head", url: PR.replace("pull/4/files", "blob/main/lib/a.rb") }] });
  const target = refTarget(page.text);
  assert.deepEqual(ids(refActions(target, viewer)), ["editor", "url:pr_diff", "url:blob", "show", "copy"]);
  assert.deepEqual(ids(refActions(target, PHONE)), ["url:pr_diff", "url:blob", "show", "copy"]);
  assert.deepEqual(refActions(target, viewer).map((a) => a.label(target)), ["Open in editor", "PR diff", "File at head", "Show in turn", "Copy path"]);
  assert.equal(refActions(target, viewer)[1].hint(target), PR);
  cleanup(page.root);
});

test("refActions: a link and a ref action to the same URL show once, at the link's place, under the action's label", () => {
  const page = turnPage();
  bindRef(page.link, { kind: "file", target: { path: "/p/lib/a.rb", line: 11 }, actions: [{ id: "pr_diff", label: "PR diff (#4)", url: PR }, { id: "again", label: "Again", url: PR }] });
  const target = refTarget(page.link);
  assert.equal(target.href, PR);
  const actions = refActions(target, viewer);
  assert.deepEqual(ids(actions), ["link", "editor", "show", "copy"]);
  assert.equal(actions[0].label(target), "PR diff (#4)");
  // Without the data (an old session), the regex label as before.
  const old = turnPage();
  assert.equal(refActions(refTarget(old.link), viewer)[0].label(refTarget(old.link)), "PR diff");
  cleanup(page.root, old.root);
});

test("refActions: another kind runs its own actions (a link first when it is one), on a phone too; none without any", () => {
  const root = mount(`<p><span>ABC-12</span> <a href="${JIRA}">ABC-12</a> <span>abc123</span></p>`);
  const [issue, link, commit] = root.querySelectorAll("span, a");
  const open = [{ id: "open", label: "Open in Jira", url: JIRA }, { id: "board", label: "Board", url: "https://jira.test/board" }];
  bindRef(issue, { kind: "issue", target: { id: "ABC-12" }, actions: open });
  bindRef(link, { kind: "issue", target: { id: "ABC-12" }, actions: open });
  bindRef(commit, { kind: "commit", target: { id: "abc123" } });
  assert.deepEqual(ids(refActions(refTarget(issue), PHONE)), ["url:open", "url:board"]);
  assert.deepEqual(ids(refActions(refTarget(issue), viewer)), ["url:open", "url:board"]);
  assert.deepEqual(ids(refActions(refTarget(link), PHONE)), ["link", "url:board"]);
  assert.equal(refActions(refTarget(link), PHONE)[0].label(refTarget(link)), "Open in Jira");
  assert.deepEqual(refActions(refTarget(commit), viewer), []);
  cleanup(root);
});

test("a ref's URL action opens a new tab: a click runs the main one, the menu any; a URL never goes to the editor", () => {
  const root = mount("<p><span>ABC-12</span> and <span>lib/a.rb</span></p>");
  const [issue, file] = root.querySelectorAll("span");
  bindRef(issue, { kind: "issue", target: { id: "ABC-12" }, actions: [{ id: "open", label: "Open in Jira", url: JIRA }, { id: "board", label: "Board", url: "https://jira.test/board" }] });
  bindRef(file, { kind: "file", target: { path: "/p/lib/a.rb" }, actions: [{ id: "pr_diff", label: "PR diff", url: PR }] });
  let current = PHONE;
  const calls = installed(root, () => current);
  click(issue);
  tap(issue);
  assert.deepEqual([...document.querySelectorAll('.ref-menu [role="menuitem"]')].map((b) => b.textContent), ["Open in Jira", "Board"]);
  click(document.querySelector('.ref-menu [data-target="url:board"]'));
  // The phone: a file ref's main target is its PR diff now (no editor).
  file.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true, pointerType: "mouse" }));
  click(file);
  current = viewer;
  click(file);
  assert.deepEqual(calls, [["link", JIRA], ["link", "https://jira.test/board"], ["link", PR], ["open", "vscode://file/p/lib/a.rb:1"]]);
  cleanup(root);
});

test("the default link opener opens a new tab with no opener and no referrer", () => {
  const root = mount("<p><span>ABC-12</span></p>");
  const issue = root.querySelector("span");
  bindRef(issue, { kind: "issue", target: { id: "ABC-12" }, actions: [{ id: "open", label: "Open in Jira", url: JIRA }] });
  const opened = [];
  const before = window.open;
  window.open = (...args) => opened.push(args);
  installRefClicks(root, () => PHONE, { selection: () => null });
  click(issue);
  window.open = before;
  assert.deepEqual(opened, [[JIRA, "_blank", "noopener,noreferrer"]]);
  cleanup(root);
});

test("a bound row title's URL actions stay on the title: its diff and read lines keep their click only", () => {
  const page = turnPage();
  const title = page.editRow.querySelector(".activity-params");
  bindRef(title, { kind: "file", target: { path: "/p/lib/a.rb" }, actions: [{ id: "pr_diff", label: "PR diff", url: PR }] });
  assert.deepEqual(ids(refActions(refTarget(title), PHONE)), ["url:pr_diff", "copy"]);
  const line = page.editRow.querySelector(".diff-line.diff-add");
  assert.deepEqual(ids(refActions(refTarget(line), viewer)), ["editor"]);
  assert.deepEqual(ids(refActions(refTarget(line), PHONE)), []);
  cleanup(page.root);
});

test("a kind named like an Object property ('constructor') is any other kind; bindRef refuses a kind the server would", () => {
  const root = mount("<p><span>a</span> <span>b</span> <span>c</span></p>");
  const [ctor, bad, after] = root.querySelectorAll("span");
  bindRef(ctor, { kind: "constructor", target: { id: "x" }, actions: [{ id: "open", label: "Open", url: JIRA }] });
  assert.deepEqual(ids(refActions(refTarget(ctor), PHONE)), ["url:open"]);
  assert.deepEqual(refActions({ kind: "toString", actions: [] }, PHONE), []);
  bindRef(bad, { kind: "Is Sue\"", target: { id: "x" }, actions: [{ id: "open", label: "Open", url: JIRA }] });
  assert.equal(bad.dataset.refKind, undefined);
  assert.equal(refTarget(bad), null);
  bindRef(after, { kind: "issue", target: { id: "y" }, actions: [{ id: "open", label: "Open", url: JIRA }] });
  syncRefTabs(root, PHONE);
  assert.equal(after.getAttribute("role"), "button");
  cleanup(root);
});

test("bindRef over a ref (a rebind, a scanned ref) replaces its target: no stale path or lines", () => {
  const root = mount('<p><span class="ref" data-ref-kind="file" data-ref-path="/p/old.rb" data-ref-line="7" data-ref-end-line="9">x</span></p>');
  const el = root.querySelector("span");
  bindRef(el, { kind: "file", target: { path: "/p/new.rb" } });
  assert.deepEqual([el.dataset.refPath, el.dataset.refLine, el.dataset.refEndLine], ["/p/new.rb", undefined, undefined]);
  assert.equal(refTarget(el).line, null);
  bindRef(el, { kind: "issue", target: { id: "ABC-1" } });
  assert.equal(el.dataset.refPath, undefined);
  assert.equal(refTarget(el).path, "");
  cleanup(root);
});

// app.js linkTextRefs' order: the touched files, each answer's plugin
// refs, then the regex scan.
function linkTextRefs(root) {
  const touched = touchedFiles([root]);
  for (const el of root.querySelectorAll(".bubble.output")) pairAnswerRefs(el);
  for (const el of root.querySelectorAll(".bubble.output")) linkRefs(el, touched, "/p");
}

test("an answer's plugin file ref on a github-pr link keeps its actions over the regex scan; the menu labels the link from the action", () => {
  const readRow = toolRowHtml({ ...editRow, key: "1:1" });
  const root = mount(
    `<details class="turn-work"><summary>steps</summary>${readRow}</details>` +
    `<div class="bubble output markdown"><p>Fixed at lib/a.rb:11, see <a href="${PR}"><code>lib/a.rb:11</code></a>.</p></div>`,
  );
  const bubble = root.querySelector(".bubble.output");
  setAnswerRefs(bubble, [{
    match: "lib/a.rb:11", kind: "file", target: { path: "/p/lib/a.rb", line: 11 },
    actions: [{ id: "pr_diff", label: "PR diff (#4)", url: PR }, { id: "blob", label: "File at head", url: PR.replace("pull/4/files", "blob/main/lib/a.rb") }],
  }]);
  linkTextRefs(root);
  const link = bubble.querySelector("a");
  const target = refTarget(link);
  const actions = refActions(target, viewer);
  assert.deepEqual(ids(actions), ["link", "editor", "url:blob", "show", "copy"]);
  assert.equal(actions[0].label(target), "PR diff (#4)");
  // The plain mention: the regex scan's (the plugin's ref won by its link).
  const [text] = bubble.querySelectorAll("span.ref");
  assert.equal(text.textContent, "lib/a.rb:11");
  assert.deepEqual(refTarget(text).actions, []);
  cleanup(root);
});

test("an issue-only answer pairs with nothing touched; its plain click opens the action", () => {
  const root = mount('<div class="bubble output"><p>Filed ABC-12.</p></div>');
  setAnswerRefs(root.querySelector(".bubble.output"), [{ match: "ABC-12", kind: "issue", target: { id: "ABC-12" }, actions: [{ id: "open", label: "Open in Jira", url: JIRA }] }]);
  assert.equal(touchedFiles([root]).size, 0);
  linkTextRefs(root);
  const issue = root.querySelector('span.ref[data-ref-kind="issue"]');
  assert.equal(issue.textContent, "ABC-12");
  const opened = [];
  installRefClicks(root, () => PHONE, { openLink: (url) => opened.push(url), menu: createRefMenu(document) });
  click(issue);
  assert.deepEqual(opened, [JIRA]);
  cleanup(root);
});
