// `path:line` refs in an answer's or a step's text (traceable refs P3).
// A name becomes a file ref (refs.js: span.ref with data-ref-kind="file")
// only when it names a file the session's rows touched (their refs): the
// answer's text is unchanged, it resolves on the page, and nothing the
// session didn't touch gets linked. The scan is github-pr's LineLinker
// (bundles/github-pr/plugin.rb) on the DOM: pre, links and fenced blocks
// are left alone, inline code only when it is the ref alone, a bare URL's
// text too.

import { refSpan } from "./refs.js";

// A path (no spaces), a line, an optional end line and an optional column
// (kept in the text, not used). LineLinker::REF.
export const REF = /(?<![\w./@+~-])(?<path>[\w./@+~-]*[\w@+~-]):(?<from>\d+)(?:-(?<to>\d+))?(?::\d+)?(?![\w/])/;
export const REF_ALONE = new RegExp(`^${REF.source}$`);
// A ref, or a bare path (no `:line`): a bare one counts only when it is a
// touched file exactly (resolveRef's +bare+). Not after a `\` or a `:`
// either: the tail of `C:\x\foo.rb:3` or `host:lib/foo.rb:3` is another
// machine's file.
const REF_OR_PATH = /(?<![\w./@+~\\:-])(?<path>[\w./@+~-]*[\w@+~-])(?::(?<from>\d+)(?:-(?<to>\d+))?(?::\d+)?(?![\w/])|(?![\w/]|:\d))/g;
const PATH_ALONE = /^(?<path>[\w./@+~-]*[\w@+~-])$/;
const URL_SPAN = /[a-z][a-z0-9+.-]*:\/\/\S+/gi;
const MARKDOWN_LINK = /\[[^\]]*\]\([^)]*\)/g;
// A fenced code block's opening line (up to 3 spaces, then ``` or ~~~).
const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/;
// Elements whose text is never scanned: code blocks, links (a github-pr
// PR link stays the PR's), a ref already made.
const SKIP = "pre, a, [data-ref-kind]";

// The ref a match names: { path, line, endLine } or null. A path has a `/`
// or an extension (`10:30` is a time, `host:8080` a port); line 0 is never
// a ref; an end line not after the line is dropped.
function refOf(groups) {
  const path = groups?.path || "";
  if (!path.includes("/") && !/\.[A-Za-z0-9]+$/.test(path)) return null;
  if (groups.from === undefined) return { path, line: null, endLine: null };
  const line = Number(groups.from);
  if (!line) return null;
  const to = groups.to === undefined ? null : Number(groups.to);
  return { path, line, endLine: to && to > line ? to : null };
}

// The absolute touched file +path+ names, or null: the path itself when
// absolute, else the path under +cwd+ (`.` and `..` folded either way); else (not for a +bare+ path: no
// `:line`) the ONE touched file ending in `/<path>`. Ambiguous: none.
export function resolveRef(path, touched, cwd, { bare = false } = {}) {
  const rel = String(path).replace(/^(?:\.\/)+/, "");
  const exact = rel.startsWith("/") ? joinPath("", rel) : cwd ? joinPath(cwd, rel) : null;
  if (exact && touched.has(exact)) return exact;
  if (bare || rel.startsWith("/")) return null;
  const tail = `/${rel.replace(/^(?:\.\.\/)+/, "")}`;
  const found = [...touched].filter((file) => file.endsWith(tail));
  return found.length === 1 ? found[0] : null;
}

// +rel+ under +dir+, `.` and `..` segments folded.
function joinPath(dir, rel) {
  const out = [];
  for (const part of `${dir}/${rel}`.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return `/${out.join("/")}`;
}

// [start, end, ref] for each ref in a plain +text+ that names a touched
// file: fenced blocks, markdown links and URLs skipped, inline code only
// as the ref alone (the span with its backticks). +touched+: a Set of
// absolute paths; +cwd+: the session's working directory.
export function textRefs(text, touched, cwd) {
  if (!touched?.size || !text) return [];
  const fences = fencedBlocks(text);
  const skipped = [...fences, ...spans(text, URL_SPAN), ...spans(text, MARKDOWN_LINK)];
  const code = inlineCode(text, fences);
  const found = [];
  for (const [start, end, inner] of code) {
    if (insideAny(skipped, start, end)) continue;
    const ref = aloneRef(inner, touched, cwd);
    if (ref) found.push([start, end, ref]);
  }
  for (const match of text.matchAll(REF_OR_PATH)) {
    const start = match.index;
    const end = start + match[0].length;
    if (insideAny(skipped, start, end) || insideAny(code, start, end)) continue;
    const ref = resolved(refOf(match.groups), touched, cwd);
    if (ref) found.push([start, end, ref]);
  }
  return found.sort((a, b) => a[0] - b[0]);
}

// The ref an inline code's text is when it is a ref (or a touched path)
// alone, else null.
function aloneRef(text, touched, cwd) {
  const inner = String(text).trim();
  const match = inner.match(REF_ALONE) || inner.match(PATH_ALONE);
  return match ? resolved(refOf(match.groups), touched, cwd) : null;
}

function resolved(ref, touched, cwd) {
  if (!ref) return null;
  const path = resolveRef(ref.path, touched, cwd, { bare: ref.line === null });
  return path ? { kind: "file", path, line: ref.line, end_line: ref.endLine } : null;
}

// The absolute paths of the file refs in the session's rows and approval
// cards under +roots+: what a text ref may name. Not an answer's own refs
// (a scanned one repeats a row's; a plugin's file ref names a file the
// session may not have touched).
export function touchedFiles(roots) {
  const touched = new Set();
  for (const root of roots) {
    for (const el of root.querySelectorAll('[data-ref-kind="file"][data-ref-path]')) {
      if (el.closest(".activity-row, .bubble.approval")) touched.add(el.dataset.refPath);
    }
  }
  return touched;
}

// Wraps the refs in +el+'s text in span.ref (refs.js clicks and
// hover them as it does a row title). Text inside pre, a link or a ref is
// left alone; an inline code element is wrapped whole when it is a ref
// alone. A link whose text is a ref alone (github-pr's PR diff link) is
// that ref itself: its href stays the plain click's, the ref's other
// targets join it in the menu (refs.js). Runs again over the same element
// without wrapping twice.
export function linkRefs(el, touched, cwd) {
  if (!el || !touched?.size) return;
  const doc = el.ownerDocument;
  for (const link of [...el.querySelectorAll("a[href]:not([data-ref-kind])")]) {
    if (link.parentElement?.closest("pre, a, [data-ref-kind]")) continue;
    const ref = aloneRef(link.textContent, touched, cwd);
    if (!ref) continue;
    link.classList.add("ref");
    for (const [name, value] of Object.entries(refSpan(doc, ref).dataset)) link.dataset[name] = value;
  }
  for (const code of [...el.querySelectorAll("code")]) {
    if (code.closest(SKIP)) continue;
    const ref = aloneRef(code.textContent, touched, cwd);
    if (!ref) continue;
    const span = refSpan(doc, ref);
    code.replaceWith(span);
    span.append(code);
  }
  const walker = doc.createTreeWalker(el, 4 /* NodeFilter.SHOW_TEXT */);
  const nodes = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const skip = node.parentElement?.closest(`${SKIP}, code`);
    if (!skip || !el.contains(skip)) nodes.push(node);
  }
  for (const node of nodes) wrapRefs(node, textRefs(node.data, touched, cwd));
}

function wrapRefs(node, hits) {
  if (!hits.length) return;
  const doc = node.ownerDocument;
  const frag = doc.createDocumentFragment();
  let pos = 0;
  for (const [start, end, ref] of hits) {
    if (start < pos) continue;
    if (start > pos) frag.append(node.data.slice(pos, start));
    const span = refSpan(doc, ref);
    span.textContent = node.data.slice(start, end);
    frag.append(span);
    pos = end;
  }
  if (pos < node.data.length) frag.append(node.data.slice(pos));
  node.replaceWith(frag);
}

// [start, end] of each fenced block (an unclosed one runs to the end).
function fencedBlocks(text) {
  const blocks = [];
  let open = null;
  let offset = 0;
  for (const line of text.split(/(?<=\n)/)) {
    const marker = line.match(FENCE_OPEN)?.[1];
    if (!open && marker) {
      open = [offset, marker];
    } else if (open && marker && marker[0] === open[1][0] && marker.length >= open[1].length && line.trim() === marker) {
      blocks.push([open[0], offset + line.length]);
      open = null;
    }
    offset += line.length;
  }
  if (open) blocks.push([open[0], text.length]);
  return blocks;
}

// [start, end, inner] of each inline code span outside +fences+: a run of
// backticks to the next run of the same length.
function inlineCode(text, fences) {
  const runs = spans(text, /`+/g).filter(([start, end]) => !insideAny(fences, start, end));
  const found = [];
  let index = 0;
  while (index < runs.length) {
    const [start, end] = runs[index];
    const closing = runs.findIndex(([s, e], k) => k > index && e - s === end - start);
    if (closing < 0) { index += 1; continue; }
    found.push([start, runs[closing][1], text.slice(end, runs[closing][0])]);
    index = closing + 1;
  }
  return found;
}

function spans(text, regex) {
  return [...text.matchAll(regex)].map((m) => [m.index, m.index + m[0].length]);
}

function insideAny(list, start, end) {
  return list.some(([s, e]) => start >= s && end <= e);
}
