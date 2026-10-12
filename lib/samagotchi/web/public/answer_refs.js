// The refs a plugin attached to an answer (the message's display_refs,
// traceable refs P5b): each {match, kind, target, label?, actions} is
// paired with the answer's bubble, then bound to what it stands for
// (refs.js bindRef), so its actions join the ref's menu.
//
// A bubble knows its message's refs through setAnswerRefs (a reload's
// render, a turn-end read's re-render); pairAnswerRefs pairs them once per
// setAnswerRefs. Three passes over all the refs, strongest evidence
// first, so a weak text match of one ref never takes another's link:
//   1. a link whose href is one of the ref's action URLs;
//   2. a link whose text is the match;
//   3. the match as a whole token inside one plain text node (not in pre,
//      a link, inline code or another ref), or an inline code that is the
//      match alone.
// A ref binds every occurrence its first finding pass finds; a ref no
// pass finds is dropped. A label that differs from the element's text is
// its hover title (unless the element has one: a markdown link's).
// The match and label are a plugin's text: they only ever go through
// textContent, setAttribute and bindRef, never markup or a RegExp.

import { bindRef, boundRef, httpUrl, refKindOk } from "./refs.js";

// bubble → {refs, paired}. A WeakMap: a dropped bubble takes its refs with
// it; the stage hand-off moves the bubble, so they move along.
const ANSWER_REFS = new WeakMap();

// Text never paired: code blocks, links (passes 1 and 2 are theirs), a ref
// already made, inline code (only as the match alone).
const SKIP = "pre, a, [data-ref-kind]";

// A token boundary, as the `path:line` scanner's (ref_scan.js REF): not
// after a path-ish character, not before a word character or a slash.
const BEFORE = /[\w./@+~-]/;
const AFTER = /[\w/]/;

// +bubble+'s refs are +refs+ (a message's display_refs: entries with a
// match and a kind bindRef binds); a non-array or one without a usable
// entry clears them. They pair on the next
// pairAnswerRefs, even when the same ones were paired before.
export function setAnswerRefs(bubble, refs) {
  if (!bubble) return;
  const list = (Array.isArray(refs) ? refs : []).filter(
    (ref) => ref && typeof ref === "object" && refKindOk(ref.kind) && typeof ref.match === "string" && ref.match.trim(),
  );
  if (list.length) ANSWER_REFS.set(bubble, { refs: list, paired: false });
  else ANSWER_REFS.delete(bubble);
}

// +bubble+'s refs (setAnswerRefs'), or null.
export function answerRefsOf(bubble) {
  return ANSWER_REFS.get(bubble)?.refs || null;
}

// Pairs +bubble+'s refs with its links and text and binds them (once per
// setAnswerRefs; again a no-op).
export function pairAnswerRefs(bubble) {
  const entry = bubble && ANSWER_REFS.get(bubble);
  if (!entry || entry.paired) return;
  entry.paired = true;
  let left = entry.refs;
  left = left.filter((ref) => !pairByHref(bubble, ref));
  left = left.filter((ref) => !pairByLinkText(bubble, ref));
  pairByText(bubble, left);
}

// The links a ref may take: not inside a code block or another ref, not
// bound by a plugin's ref already (a link the regex scanner adopted has
// attributes only: it may be bound).
function freeLinks(bubble) {
  return [...bubble.querySelectorAll("a[href]")].filter((a) => !boundRef(a) && !a.parentElement?.closest("pre, [data-ref-kind]"));
}

// Pass 1: true when +ref+ took a link to one of its action URLs.
function pairByHref(bubble, ref) {
  const urls = new Set((Array.isArray(ref.actions) ? ref.actions : []).map((action) => httpUrl(action?.url)).filter(Boolean));
  if (!urls.size) return false;
  const links = freeLinks(bubble).filter((a) => urls.has(httpUrl(a.getAttribute("href"))));
  return bindAll(links, ref);
}

// Pass 2: true when +ref+ took a link whose text is its match. The link
// goes somewhere the ref doesn't name (the model's URL): the ref's actions
// join its menu, but its label isn't the link's title.
function pairByLinkText(bubble, ref) {
  const match = ref.match.trim();
  return bindAll(freeLinks(bubble).filter((a) => a.textContent.trim() === match), ref, { label: false });
}

// Pass 3, for all the +refs+ left at once: an inline code that is a
// match alone is wrapped whole; then each text node's hits (refs in list
// order, a hit overlapping an earlier one dropped) are wrapped in one go.
function pairByText(bubble, refs) {
  if (!refs.length) return;
  const doc = bubble.ownerDocument;
  for (const code of [...bubble.querySelectorAll("code")]) {
    if (code.closest(SKIP)) continue;
    const text = code.textContent.trim();
    const ref = refs.find((candidate) => candidate.match.trim() === text);
    if (!ref) continue;
    const span = refSpan(doc, ref);
    if (!span) continue;
    code.replaceWith(span);
    span.append(code);
    labelOn(span, ref);
  }
  const walker = doc.createTreeWalker(bubble, 4 /* NodeFilter.SHOW_TEXT */);
  const nodes = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const skip = node.parentElement?.closest(`${SKIP}, code`);
    if (!skip || !bubble.contains(skip)) nodes.push(node);
  }
  const hits = new Map();
  for (const ref of refs) {
    const match = ref.match.trim();
    for (const node of nodes) {
      for (const [start, end] of tokenHits(node.data, match)) {
        const list = hits.get(node) || [];
        if (list.some(([s, e]) => start < e && end > s)) continue;
        list.push([start, end, ref]);
        hits.set(node, list);
      }
    }
  }
  for (const [node, list] of hits) wrap(node, list.sort((a, b) => a[0] - b[0]));
}

// [start, end] of each whole-token +match+ in +text+ (indexOf: the match
// is a plugin's text, never a pattern).
function tokenHits(text, match) {
  const found = [];
  for (let at = text.indexOf(match); at >= 0; at = text.indexOf(match, at + 1)) {
    const end = at + match.length;
    if (at > 0 && BEFORE.test(text[at - 1])) continue;
    if (end < text.length && AFTER.test(text[end])) continue;
    found.push([at, end]);
    at = end - 1;
  }
  return found;
}

function wrap(node, hits) {
  const doc = node.ownerDocument;
  const frag = doc.createDocumentFragment();
  let pos = 0;
  for (const [start, end, ref] of hits) {
    const span = refSpan(doc, ref);
    if (!span) continue;
    if (start > pos) frag.append(node.data.slice(pos, start));
    span.textContent = node.data.slice(start, end);
    labelOn(span, ref);
    frag.append(span);
    pos = end;
  }
  if (!pos) return;
  if (pos < node.data.length) frag.append(node.data.slice(pos));
  node.replaceWith(frag);
}

// A span bound to +ref+, or null when bindRef refuses it (a bad kind).
function refSpan(doc, ref) {
  const span = doc.createElement("span");
  bindRef(span, ref);
  return boundRef(span) ? span : null;
}

// Binds each of +els+ to +ref+; true when one took it.
function bindAll(els, ref, { label = true } = {}) {
  let bound = false;
  for (const el of els) {
    bindRef(el, ref);
    if (!boundRef(el)) continue;
    if (label) labelOn(el, ref);
    bound = true;
  }
  return bound;
}

// The ref's label as the element's hover title, when it says more than
// the element's text and the element has no title of its own.
function labelOn(el, ref) {
  const label = typeof ref.label === "string" ? ref.label.trim() : "";
  if (!label || label === el.textContent.trim() || el.hasAttribute("title")) return;
  el.setAttribute("title", label);
}
