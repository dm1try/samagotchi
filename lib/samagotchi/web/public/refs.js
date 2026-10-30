// Refs: quiet links from what a turn touched to the thing itself. A ref is
// a kind and a target: today a file tool's row title (the server's FileRef,
// {kind: "file", path, line?, end_line?}), that row's diff lines and a
// read row's numbered lines (the same file at a line), and an edit/write
// approval card's paths and its dry run's diff lines, and a `path:line` in
// an answer or a step's text (ref_scan.js; a link whose text is one too).
// The DOM carries data-ref-kind and the target's attributes, never what a
// click does: those are the ref's targets, kept per kind in REF_ACTIONS.
// A plugin's ref (the server's Ref: {kind, target, label?, actions}) is
// bound to its element by bindRef: its label and its URL actions live in a
// WeakMap off the DOM, and refTarget reads them first. Its actions join the
// kind's own (the `actions` entry); a kind the page has no table for runs
// only those. A plugin tool's row (its +refs+, bindRowRefs) puts its first
// ref on the title and the others in the title's menu (the `more` entry).
// A plain click runs the first one available (the main target); a ref
// with more shows a ▾ on hover that opens a menu of all of them
// (ref_menu.js), and a tap opens it. A ref with a target is a tab stop
// (syncRefTabs): Enter is its click, ↓ its menu. A ref with none (a phone's row title:
// no editor, and the row is the ref's own) stays plain text; refs.js marks
// a hovered or focused ref with its main target (data-ref-main), which the
// hover styling keys on.

import { escapeHtml } from "./format.js";
import { copyText } from "./copy.js";
import { createRefMenu } from "./ref_menu.js";
import { revealInHistory } from "./history_reveal.js";

// The data attributes a ref's element carries (its tab stop comes from
// syncRefTabs, for the viewer).
export function refAttrs(ref) {
  if (!ref?.kind) return "";
  const attr = (name, value) => (value ? ` data-ref-${name}="${escapeHtml(String(value))}"` : "");
  return ` data-ref-kind="${escapeHtml(ref.kind)}"${attr("path", ref.path)}${attr("line", ref.line)}${attr("end-line", ref.end_line)}`;
}

// A span with refAttrs' ref class and data attributes, for a page that
// builds DOM (ref_scan.js).
export function refSpan(doc, ref) {
  const span = doc.createElement("span");
  span.className = "ref";
  if (!ref?.kind) return span;
  span.dataset.refKind = ref.kind;
  for (const [name, value] of [["refPath", ref.path], ["refLine", ref.line], ["refEndLine", ref.end_line]]) {
    if (value) span.dataset[name] = String(value);
  }
  return span;
}

// A kind, as the server's Ref allows it (Ref::KIND).
const KIND = /^[a-z][a-z0-9_-]{0,31}$/;

// +kind+ is one bindRef binds.
export function refKindOk(kind) {
  return typeof kind === "string" && KIND.test(kind);
}

// A plugin's ref data per element (bindRef): {kind, target, label,
// actions}. A WeakMap, so a redrawn element takes its data with it.
const REF_DATA = new WeakMap();

// The longest URL the page opens: the server's RefAction::MAX_URL.
const MAX_URL = 2000;

// +url+ as the page opens it when it is an http(s) one with no userinfo
// and at most MAX_URL characters (trimmed), else null. The server's
// RefAction.http_url? checks it too; the page is at least as strict on
// userinfo, and the URL parser refuses an http(s) URL without a host. The
// page never opens another scheme a plugin gave (javascript:, data:, an
// editor's), nor a "https://github.com@evil.example/" (one host shown,
// another opened).
export function httpUrl(url) {
  if (typeof url !== "string") return null;
  const trimmed = url.trim();
  if (trimmed.length > MAX_URL) return null;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    if (parsed.username || parsed.password) return null;
    return parsed.href;
  } catch {
    return null;
  }
}

// Makes +el+ the ref +ref+ (the server's Ref#to_h): the ref class and the
// data attributes every ref carries (a file's path and lines, as refAttrs),
// its label and its actions in the WeakMap. An action without an id, a
// label or an http(s) URL is dropped; a kind the server's Ref refuses binds
// nothing. A rebind replaces the target attributes. +el+, or null without one.
export function bindRef(el, ref) {
  if (!el) return null;
  const clean = cleanRef(ref);
  if (!clean) return el;
  const { target } = clean;
  el.classList.add("ref");
  el.dataset.refKind = clean.kind;
  for (const [name, value] of [["refPath", target.path], ["refLine", target.line], ["refEndLine", target.end_line]]) {
    if (value) el.dataset[name] = String(value);
    else delete el.dataset[name];
  }
  REF_DATA.set(el, { ...clean, more: [] });
  return el;
}

// +ref+ (the server's Ref#to_h) as the page keeps it: {kind, target,
// label, actions}, its actions only those with an id, a label and an
// http(s) URL; null for a kind the server's Ref refuses.
function cleanRef(ref) {
  if (!refKindOk(ref?.kind)) return null;
  const target = ref.target && typeof ref.target === "object" ? ref.target : {};
  const actions = (Array.isArray(ref.actions) ? ref.actions : []).flatMap((action) => {
    const url = httpUrl(action?.url);
    return url && action.id && action.label ? [{ id: String(action.id), label: String(action.label), url }] : [];
  });
  return { kind: ref.kind, target, label: ref.label ? String(ref.label) : null, actions };
}

// A tool row's refs: a plugin tool's (the events' and the reloaded part's
// +refs+, the server's RowRefs: Ref#to_h each) that bindRef binds, after
// the row's own (a file tool's +ref+, as a Ref) when it has one.
function rowRefsOf(row) {
  const own = row?.ref?.kind ? [{ kind: row.ref.kind, target: { path: row.ref.path, line: row.ref.line, end_line: row.ref.end_line } }] : [];
  return [...own, ...(Array.isArray(row?.refs) ? row.refs : [])].map(cleanRef).filter(Boolean);
}

// The ref a tool row's title carries in its markup (turn_html.js, refAttrs'
// shape: {kind, path?, line?, end_line?}): the row's own, else its first
// plugin ref; null for none.
export function rowTitleRef(row) {
  const [first] = rowRefsOf(row);
  return first ? { kind: first.kind, path: first.target.path, line: first.target.line, end_line: first.target.end_line } : null;
}

// Binds a tool row's refs to its title (the element turn_html.js drew from
// +row+, live or reloaded; again after each redraw): the first as bindRef
// does, the others the title's menu offers (D8). Only for a row with a
// plugin ref: a file tool's row needs no binding (its attributes are its
// ref). The title, or null.
export function bindRowRefs(rowEl, row) {
  const title = rowEl?.querySelector?.(":scope > .activity-params[data-ref-kind]");
  if (!title || !Array.isArray(row?.refs) || !row.refs.length) return null;
  const [first, ...more] = rowRefsOf(row);
  if (!first) return null;
  bindRef(title, first);
  REF_DATA.get(title).more = more;
  return title;
}

// The plugin ref bound to +el+ (bindRef's data), or null: a row title or
// a scanned ref (attributes only) has none.
export function boundRef(el) {
  return (el && REF_DATA.get(el)) || null;
}

// The same URL either way (a link's href against an action's URL).
function sameUrl(a, b) {
  const url = httpUrl(a);
  return !!url && url === httpUrl(b);
}

// The URL +template+ ({path}, {line}; web.editor) opens +path+ at +line+
// (1 when none) with: each path segment encoded, the slashes kept. "" with
// no template or path.
export function editorUrl(template, path, line) {
  if (!template || !path) return "";
  const encoded = String(path).split("/").map(encodeURIComponent).join("/");
  return template.replaceAll("{path}", encoded).replaceAll("{line}", String(line || 1));
}

// A ref's targets, per kind, in order: the first available one is a plain
// click's (the main target), all of them are the menu's. Each says when
// it's available for +viewer+ (what this page's viewer can do: {editor,
// editorUrl}, the server's capabilities.editor and editor_url) and
// +target+ (refTarget's). A secondary one (copy) joins a ref that has
// another, never alone. A line (a diff or read line) has its click only.
// A link whose text is the ref (github-pr's PR diff): its href stays the
// plain click's, which the browser follows. Its label is the ref's action
// with the same URL (the menu shows them once), else the old guess from
// the URL (an old session's link has no ref data).
const LINK = Object.freeze({
  id: "link",
  label: (target) => target.actions?.find((action) => sameUrl(action.url, target.href))?.label ||
    (/\/pull\/\d+\/files\b/.test(target.href) ? "PR diff" : "Open link"),
  available: (_viewer, target) => !!target.href,
  run: (target, _viewer, env) => env.openLink(target.href),
});

// The ref's own actions (a plugin's, bindRef), one target each, for every
// viewer (a URL opens on a phone too): a new tab with no opener and no
// referrer. One with the link's URL, or an earlier one's, isn't repeated.
// Not on a diff or read line (its click only), which shares its title's data.
const URL_ACTIONS = Object.freeze({
  id: "actions",
  expand: (target) => (target.actions || [])
    .filter((action, at, all) => !sameUrl(action.url, target.href) && all.findIndex((other) => sameUrl(other.url, action.url)) === at)
    .map((action) => Object.freeze({
      id: `url:${action.id}`,
      label: () => action.label,
      available: (_viewer, target) => !target.isLine,
      run: (_target, _viewer, env) => env.openLink(action.url),
      hint: () => action.url,
    })),
});

// A short name for a ref in a menu of several: its label, else its id,
// else its file's name (and line).
function refName(ref) {
  if (ref.label) return ref.label;
  if (ref.target.id != null) return String(ref.target.id);
  const name = String(ref.target.path || "").split("/").pop();
  return ref.target.line ? `${name}:${ref.target.line}` : name;
}

// A row's other refs (bindRowRefs: all but the first), after the title's
// own targets: each one's actions, named "<ref> · <action>", for every
// viewer, and a file's editor (where the editor opens). A URL the menu
// already has (the link's, an action's, an earlier one's) isn't repeated.
const MORE_REFS = Object.freeze({
  id: "more",
  expand(target) {
    const seen = new Set([target.href, ...(target.actions || []).map((action) => action.url)].map(httpUrl).filter(Boolean));
    return (target.more || []).flatMap((ref, at) => {
      const name = refName(ref);
      const items = [];
      if (ref.kind === "file" && ref.target.path) {
        items.push(Object.freeze({
          id: `more:${at}:editor`,
          label: () => `${name} · Open in editor`,
          available: (viewer, target) => !target.isLine && viewer?.editor === true && !!viewer.editorUrl,
          run: (_target, viewer, env) => env.open(editorUrl(viewer.editorUrl, ref.target.path, ref.target.line)),
          hint: () => `Open the current file in your editor${ref.target.line ? ` at line ${ref.target.line}` : ""}`,
        }));
      }
      for (const action of ref.actions) {
        if (seen.has(action.url)) continue;
        seen.add(action.url);
        items.push(Object.freeze({
          id: `more:${at}:${action.id}`,
          label: () => `${name} · ${action.label}`,
          available: (_viewer, target) => !target.isLine,
          run: (_target, _viewer, env) => env.openLink(action.url),
          hint: () => action.url,
        }));
      }
      return items;
    });
  },
});

export const REF_ACTIONS = Object.freeze({
  file: Object.freeze([
    LINK,
    Object.freeze({
      id: "editor",
      label: () => "Open in editor",
      available: (viewer) => viewer?.editor === true && !!viewer.editorUrl,
      url: (target, viewer) => editorUrl(viewer.editorUrl, target.path, target.line),
      run(target, viewer, env) {
        const url = this.url(target, viewer);
        if (url) env.open(url);
      },
      // The hover hint: it opens the file as it is now.
      hint: (target) => `Open the current file in your editor${target.line ? ` at line ${target.line}` : ""}`,
    }),
    URL_ACTIONS,
    // The row that touched the file, in the turn: not for a row's own
    // title or lines (they are in the turn already).
    Object.freeze({
      id: "show",
      label: () => "Show in turn",
      available: (_viewer, target) => !target.isLine && !target.owner?.matches?.(".activity-row") && !!turnRowFor(target),
      run: (target, _viewer, env) => env.show(target),
      hint: () => "Show the row that touched it in the turn",
    }),
    MORE_REFS,
    Object.freeze({
      id: "copy",
      label: () => "Copy path",
      secondary: true,
      available: (_viewer, target) => !target.isLine && !!target.path,
      run: (target, _viewer, env) => env.copy(target.path),
    }),
  ]),
  // Any other kind (a plugin's issue, commit, …): its link, then its
  // actions, then a row's other refs.
  "*": Object.freeze([LINK, URL_ACTIONS, MORE_REFS]),
});

// The targets +viewer+ has for +target+ (refTarget's), in order; none
// when only a secondary one is.
export function refActions(target, viewer, actions = REF_ACTIONS) {
  if (!target) return [];
  // Own keys only: a kind named like an Object property ("constructor") is
  // any other kind.
  const table = (Object.hasOwn(actions, target.kind) ? actions[target.kind] : actions["*"]) || [];
  const found = table.flatMap((action) => (action.expand ? action.expand(target) : [action])).filter((action) => action.available(viewer, target));
  return found.some((action) => !action.secondary) ? found : [];
}

// What owns a ref and its diff lines: a tool row, or an edit's approval
// card (its paths and its dry run).
const OWNERS = ".activity-row, .bubble.approval";

// A line of the owner's file: a diff line, or a read row's numbered line.
const LINES = ".diff-line[data-line], .read-line[data-line]";

// What a click on +el+ points at: {kind, path, id, label, actions, more,
// line, owner, el, isLine, href} or null (+id+, +label+, +actions+ and
// +more+ (a row's other refs, bindRowRefs) a plugin's
// ref's, bindRef: the WeakMap is read first). A row title (or an approval card's path) opens its file
// at the lines the call named (an edit without any at its first changed
// line); a diff line (or a hunk header) or a read row's numbered line, in
// a row or a card with a ref, opens that file at that line. +el+ is the
// ref's element (the line for a line), +href+ a link ref's.
// A diff line elsewhere is none.
export function refTarget(el) {
  const title = el?.closest?.("[data-ref-kind]");
  if (title) {
    const owner = title.closest(OWNERS);
    const href = title.matches("a[href]") ? title.getAttribute("href") : null;
    const own = targetOf(title);
    return { ...own, line: own.line || firstChange(owner), owner: owner || title, el: title, isLine: false, href };
  }
  const diffLine = el?.closest?.(LINES);
  const owner = diffLine?.closest(OWNERS);
  const ref = owner?.querySelector("[data-ref-kind]");
  if (!ref) return null;
  return { ...targetOf(ref), line: Number(diffLine.dataset.line), owner, el: diffLine, isLine: true, href: null };
}

function targetOf(el) {
  const data = REF_DATA.get(el);
  if (!data) return { kind: el.dataset.refKind, path: el.dataset.refPath || "", line: Number(el.dataset.refLine) || null, id: null, label: null, actions: [], more: [] };
  // Bound data is the whole ref: no fallback to the attributes.
  const { target } = data;
  return {
    kind: data.kind, path: target.path || "", line: Number(target.line) || null, id: target.id ?? null, label: data.label, actions: data.actions,
    more: data.more,
  };
}

// An edit/write without a line range opens at its first changed line (its
// diff knows it, the call doesn't); null without a diff.
function firstChange(row) {
  const line = row?.querySelector(".diff-line.diff-add[data-line], .diff-line.diff-del[data-line]");
  return line ? Number(line.dataset.line) : null;
}

// The tool row that touched +target+'s file, for "show in turn", or null:
// a row with a ref to the same file that isn't the ref's own. Looked for
// in the ref's own step (a step's text comes before its rows), then its
// own turn (turnBlockOf), then the rows before it, then the nearest after
// it; in the first of those that has any, the last one showing the ref's
// line, else the last one (after it: the nearest).
export function turnRowFor(target) {
  const el = target?.el;
  if (!el?.ownerDocument || !target.path) return null;
  const rows = [...el.ownerDocument.querySelectorAll(".activity-row")].filter((row) => {
    if (row.contains(el)) return false;
    const ref = row.querySelector("[data-ref-kind]");
    return ref?.dataset.refKind === target.kind && ref.dataset.refPath === target.path;
  });
  const step = el.closest("details.gen");
  const turn = turnBlockOf(el);
  const before = rows.filter((row) => precedes(row, el));
  const pools = [
    step ? rows.filter((row) => step.contains(row)) : [],
    turn ? rows.filter((row) => turn.contains(row)) : [],
    before,
    rows.filter((row) => !before.includes(row)).reverse(),
  ];
  const pool = pools.find((found) => found.length);
  if (!pool) return null;
  const showing = target.line ? pool.filter((row) => lineIn(row, target.line)) : [];
  return showing.at(-1) || pool.at(-1);
}

// What holds +el+'s turn's rows: the steps block it is in, the stage (a
// live turn: its answer comes before its cloud), else the nearest steps
// block before it with no prompt between them (an answer, a card, in the
// history). null when there is none.
function turnBlockOf(el) {
  const own = el.closest(".turn-work, .turn-stage");
  if (own) return own;
  const doc = el.ownerDocument;
  const block = [...doc.querySelectorAll(".turn-work")].filter((b) => precedes(b, el)).at(-1);
  if (!block) return null;
  const prompt = [...doc.querySelectorAll(".bubble.user")].some((u) => precedes(block, u) && precedes(u, el));
  return prompt ? null : block;
}

// +a+ comes before +b+ in the page (and doesn't hold it).
function precedes(a, b) {
  return !a.contains(b) && !!(a.compareDocumentPosition(b) & 4 /* Node.DOCUMENT_POSITION_FOLLOWING */);
}

// +row+'s line +line+: an added or context diff line first (a removed one
// shares its number), then a read line; null when it doesn't show it.
function lineIn(row, line) {
  for (const selector of [".diff-line.diff-add", ".diff-line.diff-ctx", ".read-line", ".diff-line"]) {
    const found = row.querySelector(`${selector}[data-line="${Number(line)}"]`);
    if (found) return found;
  }
  return null;
}

// "Show in turn": opens what hides the row that touched +target+'s file
// (the turn's steps, its step), its diff (or the read that shows the
// line), scrolls to the line (else the row) and flashes both. A view that
// hides its rows its own way (the stage's cloud) opens on the row's
// ref:reveal event, which bubbles; a view that grows for it first sets the
// event's detail.until (a promise), and the scroll waits for it. The row,
// or null when there is none.
export function showInTurn(target, { behavior = smoothScroll() } = {}) {
  const row = turnRowFor(target);
  if (!row) return null;
  return showRow(row, { line: target.line, behavior });
}

// Shows a tool row: what hides it opened (history_reveal.js: its step, its
// turn's block; a view that hides its rows its own way opens on the row's
// ref:reveal event), its diff (or the read showing +line+) opened, scrolled
// to the line (else the row) and both flashed. The working set's step tags jump
// here. The row.
export function showRow(row, { line: lineNo = null, behavior = smoothScroll() } = {}) {
  const view = row.ownerDocument.defaultView || globalThis;
  const reveal = new view.CustomEvent("ref:reveal", { bubbles: true, detail: {} });
  row.dispatchEvent(reveal);
  const line = lineNo ? lineIn(row, lineNo) : null;
  const fold = line?.closest("details.activity-diff, details.activity-read") || row.querySelector("details.activity-diff");
  revealInHistory(line || fold || row);
  if (fold) fold.open = true;
  const scroll = () => (line || row).scrollIntoView?.({ block: "center", behavior });
  if (reveal.detail?.until) reveal.detail.until.then(scroll);
  else scroll();
  for (const el of [row, line].filter(Boolean)) flash(el);
  return row;
}

const FLASH_MS = 1600;

function flash(el) {
  el.classList.remove("ref-flash");
  void el.offsetWidth; // restarts the animation on a second show
  el.classList.add("ref-flash");
  clearTimeout(el._refFlash);
  el._refFlash = setTimeout(() => el.classList.remove("ref-flash"), FLASH_MS);
}

function smoothScroll() {
  return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth";
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

// A link ref's href or a ref's URL action: a new tab, as the answer's
// links open, with no opener and no referrer (the page's LAN URL and
// session id stay here).
function defaultOpenLink(href) {
  window.open(href, "_blank", "noopener,noreferrer");
}

// One delegated listener set on +root+ for every ref on the page.
// +viewer+() is read per click, key and hover, so a capabilities change
// (another session, a reload) is seen. The targets run through: +open+(url)
// (the editor's URL), +openLink+(href), +show+(target) and +copy+(text).
// +menu+ is the ▾ and its menu (ref_menu.js).
export function installRefClicks(root, viewer, {
  open = defaultOpen, openLink = defaultOpenLink, show = (target) => showInTurn(target), copy = copyText,
  selection = () => window.getSelection?.(), menu = createRefMenu(root.ownerDocument),
} = {}) {
  const env = { open, openLink, show, copy };
  const run = (action, target) => action.run(target, viewer(), env);
  const items = (actions, target) => actions.map((action) => ({
    id: action.id, label: action.label(target), hint: action.hint?.(target) || "", run: () => run(action, target),
  }));
  const openMenu = (target, actions, options) => menu.open(target.el, items(actions, target), options);
  // The last pointer's type: a tap opens the menu, a mouse click runs the
  // main target.
  let pointer = "mouse";
  root.addEventListener("pointerdown", (e) => { pointer = e.pointerType || "mouse"; }, true);
  // A key press: the keyboard leads now (Enter on a link after a tap is
  // the link's own click); Tab works out the tab stops before it moves.
  root.addEventListener("keydown", (e) => {
    pointer = "keyboard";
    if (e.key === "Tab") syncRefTabs(root, viewer());
  }, true);

  root.addEventListener("click", (e) => {
    if (e.button !== 0 || e.defaultPrevented) return;
    const target = refTarget(e.target);
    if (!target) return;
    const actions = refActions(target, viewer());
    if (!actions.length) return;
    if (selectingIn(target.owner, selection())) return;
    if (pointer === "touch" && !target.isLine && actions.length > 1) {
      e.preventDefault();
      e.stopPropagation();
      openMenu(target, actions, { focus: false });
      return;
    }
    // A link's own click: the browser follows it.
    if (actions[0].id === "link") return;
    e.preventDefault();
    e.stopPropagation();
    run(actions[0], target);
  });

  // A focused ref: Enter is its main target (a link's Enter is its own
  // click), ↓ opens the menu with the first target focused, Esc hides the ▾.
  root.addEventListener("keydown", (e) => {
    if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
    const el = e.target;
    if (!el?.matches?.("[data-ref-kind]")) return;
    if (e.key === "Escape") menu.hideMore();
    if (e.key !== "Enter" && e.key !== "ArrowDown") return;
    const target = refTarget(el);
    const actions = refActions(target, viewer());
    if (!actions.length) return;
    if (e.key === "Enter") {
      if (actions[0].id === "link") return;
      e.preventDefault();
      run(actions[0], target);
    } else if (actions.length > 1) {
      e.preventDefault();
      openMenu(target, actions, { focus: true });
    }
  });

  // On hover or focus: the ref's main target on it (data-ref-main, for the
  // styling), its hover hint, and the ▾ when it has more than one (not
  // after a tap, which opens the menu itself).
  const mark = (e) => {
    const target = refTarget(e.target);
    if (!target) return;
    const actions = refActions(target, viewer());
    const el = target.el;
    if (actions.length) el.dataset.refMain = actions[0].id;
    else delete el.dataset.refMain;
    if (!target.isLine) setRefRole(el, actions);
    hint(el, target, actions[0]);
    if (!target.isLine && actions.length > 1 && pointer !== "touch") menu.showMore(el, () => openMenu(refTarget(el), refActions(refTarget(el), viewer()), { focus: true }));
  };
  root.addEventListener("mouseover", mark);
  root.addEventListener("focusin", mark);
  const leave = (e) => {
    const el = e.target?.closest?.("[data-ref-kind]");
    if (el && !el.contains(e.relatedTarget)) menu.hideMoreSoon(el);
  };
  root.addEventListener("mouseout", leave);
  root.addEventListener("focusout", leave);
}

// The tab stops under +root+ for +viewer+: a ref is one (a button, with
// aria-haspopup when it has a menu) only while it has a target, so a
// phone's or an editorless viewer's row titles aren't. Worked out before a
// Tab moves the focus and on a ref's hover or focus; a line never is one.
export function syncRefTabs(root, viewer) {
  for (const el of root.querySelectorAll("[data-ref-kind]")) setRefRole(el, refActions(refTarget(el), viewer));
}

function setRefRole(el, actions) {
  if (actions.length > 1) el.setAttribute("aria-haspopup", "menu");
  else el.removeAttribute("aria-haspopup");
  // A link is focusable and a link already.
  if (el.matches("a[href]")) return;
  if (actions.length) {
    el.tabIndex = 0;
    el.setAttribute("role", "button");
  } else {
    el.removeAttribute("tabindex");
    el.removeAttribute("role");
  }
}

// The hover hint, on the ref's own element, worked out on each hover (the
// viewer can change): its own title (a row title's hover) first, then the
// main target's hint when it has one.
function hint(el, target, action) {
  if (el.dataset.refTitle === undefined) el.dataset.refTitle = el.getAttribute("title") || "";
  const own = el.dataset.refTitle;
  const title = [own, action?.hint ? action.hint(target) : ""].filter(Boolean).join("\n");
  if (title) el.setAttribute("title", title);
  else el.removeAttribute("title");
}
