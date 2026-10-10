// Refs: quiet links from what a turn touched to the thing itself. A ref is
// a kind and a target: today a file tool's row title (the server's FileRef,
// {kind: "file", path, line?, end_line?}) and that row's diff lines (the
// same file at a line). The DOM carries data-ref-kind and the target's
// attributes, never what a click does: that is an action, kept per kind in
// REF_ACTIONS, and a click runs the first one available to this viewer. A
// ref with none (a phone: no editor) stays plain text; the page marks the
// kinds that have one on its body (refs-<kind>), which the hover styling
// keys on.

import { escapeHtml } from "./format.js";

// The data attributes a ref's element carries.
export function refAttrs(ref) {
  if (!ref?.kind) return "";
  const attr = (name, value) => (value ? ` data-ref-${name}="${escapeHtml(String(value))}"` : "");
  return ` data-ref-kind="${escapeHtml(ref.kind)}"${attr("path", ref.path)}${attr("line", ref.line)}${attr("end-line", ref.end_line)}`;
}

// The URL +template+ ({path}, {line}; web.editor) opens +path+ at +line+
// (1 when none) with: each path segment encoded, the slashes kept. "" with
// no template or path.
export function editorUrl(template, path, line) {
  if (!template || !path) return "";
  const encoded = String(path).split("/").map(encodeURIComponent).join("/");
  return template.replaceAll("{path}", encoded).replaceAll("{line}", String(line || 1));
}

// What a ref can do, per kind, in order: the first available one is a
// click's. +viewer+ is what this page's viewer can do ({editor, editorUrl}:
// the server's capabilities.editor and editor_url).
export const REF_ACTIONS = Object.freeze({
  file: Object.freeze([
    Object.freeze({
      id: "editor",
      available: (viewer) => viewer?.editor === true && !!viewer.editorUrl,
      url: (target, viewer) => editorUrl(viewer.editorUrl, target.path, target.line),
      // The hover hint: it opens the file as it is now.
      hint: (target) => `Open the current file in your editor${target.line ? ` at line ${target.line}` : ""}`,
    }),
  ]),
});

// The first action +viewer+ has for a ref of +kind+, else null.
export function refAction(kind, viewer, actions = REF_ACTIONS) {
  return (actions[kind] || []).find((action) => action.available(viewer)) || null;
}

// The kinds that have an action for +viewer+ (the page's refs-<kind> classes).
export function availableKinds(viewer, actions = REF_ACTIONS) {
  return Object.keys(actions).filter((kind) => refAction(kind, viewer, actions));
}

// What a click on +el+ points at: {kind, path, line, owner} or null. A row
// title opens its file at the lines the call named (an edit without any at
// its first changed line); a diff line (or a hunk header) in a row with a
// ref opens the row's file at that line. A diff line outside a row (an
// approval card's dry run) is none.
export function refTarget(el) {
  const title = el?.closest?.("[data-ref-kind]");
  if (title) {
    const owner = title.closest(".activity-row");
    return { ...targetOf(title), line: Number(title.dataset.refLine) || firstChange(owner), owner: owner || title };
  }
  const diffLine = el?.closest?.(".diff-line[data-line]");
  const owner = diffLine?.closest(".activity-row");
  const ref = owner?.querySelector("[data-ref-kind]");
  if (!ref) return null;
  return { ...targetOf(ref), line: Number(diffLine.dataset.line), owner };
}

function targetOf(el) {
  return { kind: el.dataset.refKind, path: el.dataset.refPath || "" };
}

// An edit/write without a line range opens at its first changed line (its
// diff knows it, the call doesn't); null without a diff.
function firstChange(row) {
  const line = row?.querySelector(".diff-line.diff-add[data-line], .diff-line.diff-del[data-line]");
  return line ? Number(line.dataset.line) : null;
}

// A drag that selected text in the clicked ref's row isn't a click on the
// ref. A selection elsewhere on the page (or a collapsed one) doesn't count.
function selectingIn(owner, selection) {
  if (!selection || selection.isCollapsed || !owner) return false;
  return [selection.anchorNode, selection.focusNode].some((node) => node && owner.contains(node));
}

function defaultOpen(url) {
  // The e2e seam (spec/e2e): a spec defines it before the page loads.
  if (typeof window.__chiRefOpen === "function") window.__chiRefOpen(url);
  else window.location.href = url;
}

// One delegated listener on +root+ for every ref on the page. +viewer+()
// is read per click and hover, so a capabilities change (another session,
// a reload) is seen; +open+(url) opens an action's URL.
export function installRefClicks(root, viewer, { open = defaultOpen, selection = () => window.getSelection?.() } = {}) {
  root.addEventListener("click", (e) => {
    if (e.button !== 0 || e.defaultPrevented) return;
    const target = refTarget(e.target);
    if (!target) return;
    const action = refAction(target.kind, viewer());
    if (!action) return;
    if (selectingIn(target.owner, selection())) return;
    const url = action.url(target, viewer());
    if (!url) return;
    e.preventDefault();
    e.stopPropagation();
    open(url);
  });
  // The hover hint, on the ref's own element, worked out on each hover
  // (the viewer can change): its own title (a row title's hover) first,
  // then the action's hint when there is one.
  root.addEventListener("mouseover", (e) => {
    const target = refTarget(e.target);
    if (!target) return;
    const el = e.target.closest("[data-ref-kind]") || e.target.closest(".diff-line[data-line]");
    if (!el) return;
    if (el.dataset.refTitle === undefined) el.dataset.refTitle = el.getAttribute("title") || "";
    const own = el.dataset.refTitle;
    const action = refAction(target.kind, viewer());
    const title = [own, action ? action.hint(target) : ""].filter(Boolean).join("\n");
    if (title) el.setAttribute("title", title);
    else el.removeAttribute("title");
  });
}

// The body's classes for +viewer+: refs-<kind> for each kind with an action.
export function setRefKinds(body, viewer, actions = REF_ACTIONS) {
  const kinds = availableKinds(viewer, actions);
  for (const kind of Object.keys(actions)) body.classList.toggle(`refs-${kind}`, kinds.includes(kind));
}
