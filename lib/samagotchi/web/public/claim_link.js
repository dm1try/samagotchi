// A link to a claim (docs/internals/participants.md, Deep links): one turn
// of a session and a quote in it, on either page.
//
//   participant page:  <chi web>/#s=<id>&t=<turn8>&q=<quote>&p=<prefix>
//   owner's page:      #/s/<id>?t=<turn8>&q=<quote>&p=<prefix>
//
// t is the turn's id, its first 8 characters (a turn-opening message's
// turn_id, data-turn-id in the DOM); q the selection's rendered text,
// normalized and at most QUOTE_MAX characters; p the PREFIX_MAX characters
// before it in the same bubble, to tell two equal quotes apart (left out
// when there are none). URLSearchParams encodes both, so a link is
// URL-safe and a space is one "+".
//
// Normalized: whitespace collapsed, and what the participant page shows
// instead (ParticipantView::Redact): secret shapes "[redacted]" (so a link
// never carries one, and matches the participant's redacted text), and on
// the owner's page the session's folder relative ("<cwd>/x" → "x",
// "<cwd>" → "."), the home folder "~". Not the owner's token (Redact's
// viewer secrets): the page doesn't hold it.
//
// Opening one: the quote's bubble scrolled to and marked (the quote itself
// by the CSS Highlight API, where the browser has it); a quote not found
// marks the turn; a turn not found (one the page doesn't stamp) is looked
// for in the whole page, and then is the caller's (top + a toast).
//
// The text work is pure; the DOM part reads only Element/Range/TreeWalker,
// so it runs under `node --test` with happy-dom. A module of its own:
// static JS is cached at unversioned URLs, and a new export on an old
// module would blank the page.

export const QUOTE_MAX = 200;
export const PREFIX_MAX = 32;
export const TURN_CHARS = 8;
// The CSS highlight's name (::highlight(chi-claim)) and the marked
// element's class.
export const HIGHLIGHT = "chi-claim";
export const HIT_CLASS = "claim-hit";

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export const MARK = "[redacted]";
// ParticipantView::Redact's PATTERNS and VALUES
// (lib/samagotchi/web/participant_view.rb), as JS: keep them in step.
// spec/fixtures/redact_cases.json holds cases both sides read the same
// (participant_view_spec.rb, claim_link.test.js).
const SECRET_PATTERNS = [
  /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)/g,
  /\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}/g,
  /\bgh[pousr]_[A-Za-z0-9]{20,}/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/g,
  /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}/g,
  /\bchp_[A-Za-z0-9_-]{20,}/g,
  /\bchc_[A-Za-z0-9_-]{43}/g,
  /\bAIza[0-9A-Za-z_-]{30,}/g,
  /\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
  /https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9/_-]+/g,
];
// The value after group 1 is the secret.
const SECRET_VALUES = [
  /(\b(?:Authorization|X-Chi-Bridge):\s*(?:Bearer\s+|Basic\s+|Token\s+)?)[^\s"'`]+/gi,
  /((?<![A-Za-z0-9])[A-Za-z0-9_-]*?(?:token|api[_-]?key|access[_-]?key|secret|password|passwd)["']?\s*[=:]\s*["']?)[^\s"'&`,;}]+/gi,
  /(\b[a-z][a-z0-9+.-]*:\/\/[^/\s:@]+:)[^@\s/]+(?=@)/gi,
];

// The secrets in +raw+ as [{start, end, text: MARK}]; overlapping ones
// (a token= value holding a key shape) one span, as Redact's passes in a
// row leave one mark.
function secretSpans(raw) {
  const found = [];
  for (const re of SECRET_PATTERNS) for (const m of raw.matchAll(re)) found.push([m.index, m.index + m[0].length]);
  for (const re of SECRET_VALUES) {
    for (const m of raw.matchAll(re)) found.push([m.index + m[1].length, m.index + m[0].length]);
  }
  found.sort((a, b) => a[0] - b[0]);
  const spans = [];
  for (const [start, end] of found) {
    const last = spans[spans.length - 1];
    if (last && start < last.end) last.end = Math.max(last.end, end);
    else spans.push({ start, end, text: MARK });
  }
  return spans;
}

// The spans of +raw+ that read differently on the participant page:
// [{start, end, text}], in order, not overlapping. Secrets first, then
// the session's folder (it is usually under home), as Redact.text.
function replacements(raw, { home = "", cwd = "" } = {}) {
  const spans = secretSpans(raw);
  const taken = (s, e) => spans.some((r) => s < r.end && e > r.start);
  if (cwd.length > 1) {
    for (const m of raw.matchAll(new RegExp(`${escapeRegExp(cwd)}(/|(?=\\b|$))`, "g"))) {
      const end = m.index + m[0].length;
      if (!taken(m.index, end)) spans.push({ start: m.index, end, text: m[1] === "/" ? "" : "." });
    }
  }
  if (home.length > 1) {
    for (const m of raw.matchAll(new RegExp(`${escapeRegExp(home)}(?=/|\\b|$)`, "g"))) {
      const end = m.index + m[0].length;
      if (!taken(m.index, end)) spans.push({ start: m.index, end, text: "~" });
    }
  }
  return spans.sort((a, b) => a.start - b.start);
}

// +raw+ normalized, with where each of its characters came from: text,
// and starts[i]/ends[i] the raw offsets character i covers.
export function normalizeWithMap(raw, opts = {}) {
  const source = String(raw ?? "");
  const spans = replacements(source, opts);
  let text = "";
  const starts = [];
  const ends = [];
  let space = null;
  const put = (ch, start, end) => {
    if (/\s/.test(ch)) {
      if (space) space.end = end;
      else if (text) space = { start, end };
      return;
    }
    if (space) {
      text += " ";
      starts.push(space.start);
      ends.push(space.end);
      space = null;
    }
    text += ch;
    starts.push(start);
    ends.push(end);
  };
  let i = 0;
  let next = 0;
  while (i < source.length) {
    const span = spans[next];
    if (span && span.start === i) {
      // A folder shown "." or "" (its "/" gone) maps to the whole span.
      for (const ch of span.text) put(ch, span.start, span.end);
      i = span.end;
      next += 1;
      continue;
    }
    put(source[i], i, i + 1);
    i += 1;
  }
  return { text, starts, ends };
}

export function normalizeClaim(raw, opts = {}) {
  return normalizeWithMap(raw, opts).text;
}

// The first +max+ characters of +text+ (or the last, +fromEnd+), never
// half a surrogate pair.
function clip(text, max, fromEnd = false) {
  const chars = Array.from(text);
  if (chars.length <= max) return text;
  return (fromEnd ? chars.slice(-max) : chars.slice(0, max)).join("");
}

// The claim's q and p for a selection: +selected+ its text, +before+ and
// +after+ the bubble's text around it. Normalized together, so a secret
// the selection cuts into is read whole and marked whole (never a piece
// of it in the link), and the prefix ends as the page reads it (one space
// between it and the quote, or none). q is "" when the selection holds no
// text.
export function claimQuote(selected, before = "", opts = {}, after = "") {
  const pre = String(before ?? "");
  const from = pre.length;
  const to = from + String(selected ?? "").length;
  const { text, starts, ends } = normalizeWithMap(`${pre}${selected ?? ""}${after ?? ""}`, opts);
  let a = 0;
  while (a < text.length && ends[a] <= from) a += 1;
  let b = text.length;
  while (b > a && starts[b - 1] >= to) b -= 1;
  while (a < b && text[a] === " ") a += 1;
  while (b > a && text[b - 1] === " ") b -= 1;
  const q = text.slice(a, b);
  if (!q) return { q: "", p: "" };
  return { q: clip(q, QUOTE_MAX), p: clip(text.slice(0, a), PREFIX_MAX, true) };
}

// "t=…&q=…&p=…" for a claim {turnId, q, p}; empty parts left out.
export function claimParams({ turnId = "", q = "", p = "" } = {}) {
  const params = new URLSearchParams();
  if (turnId) params.set("t", String(turnId).slice(0, TURN_CHARS));
  if (q) params.set("q", q);
  if (q && p) params.set("p", p);
  return params.toString();
}

// The participant page's link: +base+ the participant link's origin
// ("https://chi.example/", "http://192.168.1.5:4567/"), no token.
export function participantClaimLink(base, sessionId, claim) {
  const params = claimParams(claim);
  const root = String(base || "").replace(/#.*$/, "").replace(/\/?$/, "/");
  return `${root}#s=${encodeURIComponent(sessionId)}${params ? `&${params}` : ""}`;
}

// The owner's page's hash for the claim.
export function ownerClaimHash(sessionId, claim) {
  const params = claimParams(claim);
  return `#/s/${encodeURIComponent(sessionId)}${params ? `?${params}` : ""}`;
}

// {sessionId, turn, q, p} from either page's hash, or null when it names
// no turn (a bare session link). The owner's page reads both forms: the
// participant link opened in the owner's browser shows the owner's page.
export function claimFromHash(hash) {
  const raw = String(hash || "");
  let id = null;
  let query = "";
  const owner = /^#\/s\/([^/?#]+)\?(.*)$/.exec(raw);
  if (owner) {
    try { id = decodeURIComponent(owner[1]); } catch { return null; }
    query = owner[2];
  } else if (raw.startsWith("#") && !raw.startsWith("#/")) {
    query = raw.slice(1);
  } else {
    return null;
  }
  let params;
  try { params = new URLSearchParams(query); } catch { return null; }
  id ||= params.get("s");
  const turn = params.get("t") || "";
  if (!id || !/^[0-9a-f-]{1,36}$/i.test(turn)) return null;
  return { sessionId: id, turn: turn.toLowerCase(), q: params.get("q") || "", p: params.get("p") || "" };
}

// Where the claim's text is in +texts+ (each root's raw text): {at, start,
// end} raw offsets in texts[at], or null. The prefix and the quote
// together first, then the quote alone (the bubble's text before it may
// read differently on the other page).
export function findClaim(texts, { q = "", p = "" } = {}, opts = {}) {
  if (!q) return null;
  const maps = texts.map((t) => normalizeWithMap(t, opts));
  const needles = p ? [[`${p}${q}`, p.length], [q, 0]] : [[q, 0]];
  for (const [needle, skip] of needles) {
    for (let at = 0; at < maps.length; at += 1) {
      const found = maps[at].text.indexOf(needle);
      if (found < 0) continue;
      const first = found + skip;
      const last = found + needle.length - 1;
      return { at, start: maps[at].starts[first], end: maps[at].ends[last] };
    }
  }
  return null;
}

// ---- The DOM ----

// The turn-opening element whose data-turn-id starts with +turn+ in
// +container+, and the roots (+rootSelector+) from it to the next turn's
// opening: {anchor, roots}, or null.
export function turnRoots(container, turn, rootSelector) {
  const anchors = [...container.querySelectorAll("[data-turn-id]")];
  const at = anchors.findIndex((a) => turn && String(a.dataset.turnId || "").toLowerCase().startsWith(turn));
  if (at < 0) return null;
  const anchor = anchors[at];
  const next = anchors[at + 1] || null;
  const FOLLOWING = 4;
  const roots = [...container.querySelectorAll(rootSelector)].filter((el) =>
    (anchor === el || anchor.contains(el) || (anchor.compareDocumentPosition(el) & FOLLOWING))
    && (!next || (!next.contains(el) && (el.compareDocumentPosition(next) & FOLLOWING))));
  return { anchor, roots };
}

// The turn id of the turn +node+ is in (the last turn opening at or before
// it in +container+), or null.
export function turnIdOf(container, node) {
  let found = null;
  const PRECEDING = 2;
  for (const anchor of container.querySelectorAll("[data-turn-id]")) {
    if (anchor === node || anchor.contains(node) || (node.compareDocumentPosition(anchor) & PRECEDING)) found = anchor;
    else break;
  }
  return found?.dataset.turnId || null;
}

// +root+'s text nodes and their text joined: {text, nodes: [{node, start}]}.
function textOf(root, doc) {
  const walker = doc.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */);
  const nodes = [];
  let text = "";
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    nodes.push({ node: n, start: text.length });
    text += n.data;
  }
  return { text, nodes };
}

// The text node and offset of raw offset +at+ in a textOf result.
function pointAt({ nodes }, at, end = false) {
  for (let i = nodes.length - 1; i >= 0; i -= 1) {
    const { node, start } = nodes[i];
    if (at > start || (at === start && !end) || i === 0) return { node, offset: Math.min(Math.max(at - start, 0), node.data.length) };
  }
  return null;
}

// The claim for a selection in +root+ (+range+ in it), as claimQuote's.
export function selectionClaim(root, range, opts = {}, doc = globalThis.document) {
  const before = doc.createRange();
  before.setStart(root, 0);
  before.setEnd(range.startContainer, range.startOffset);
  const after = doc.createRange();
  after.setStart(range.endContainer, range.endOffset);
  after.setEnd(root, root.childNodes.length);
  return claimQuote(range.toString(), before.toString(), opts, after.toString());
}

// Finds the claim +claim+ ({turn, q, p}) in +container+ and shows it: the
// match's root (or the turn's opening) scrolled to the middle and marked
// HIT_CLASS, its closed <details> opened, the quote highlighted (CSS
// Highlight API). Without the turn (no opening carries its id: a
// non-person turn), the quote in any root of the page. @return "quote",
// "turn" or null (neither the turn nor the quote).
export function showClaim(container, claim, { roots: rootSelector, opts = {}, doc = globalThis.document, win = globalThis.window } = {}) {
  clearClaim(container, { doc, win });
  const turn = turnRoots(container, claim.turn, rootSelector);
  const roots = turn ? turn.roots : [...container.querySelectorAll(rootSelector)];
  const texts = roots.map((root) => textOf(root, doc));
  const hit = findClaim(texts.map((t) => t.text), claim, opts);
  if (!hit && !turn) return null;
  const el = hit ? roots[hit.at] : turn.anchor;
  for (let d = el.parentElement?.closest("details"); d; d = d.parentElement?.closest("details")) d.open = true;
  el.classList.add(HIT_CLASS);
  el.scrollIntoView?.({ block: "center" });
  if (hit) {
    const start = pointAt(texts[hit.at], hit.start);
    const end = pointAt(texts[hit.at], hit.end, true);
    const highlights = win?.CSS?.highlights;
    if (start && end && highlights && typeof win.Highlight === "function") {
      const range = doc.createRange();
      range.setStart(start.node, start.offset);
      range.setEnd(end.node, end.offset);
      highlights.set(HIGHLIGHT, new win.Highlight(range));
    }
  }
  return hit ? "quote" : "turn";
}

// The mark and highlight showClaim left, gone.
export function clearClaim(container, { win = globalThis.window } = {}) {
  for (const el of container.querySelectorAll(`.${HIT_CLASS}`)) el.classList.remove(HIT_CLASS);
  win?.CSS?.highlights?.delete?.(HIGHLIGHT);
}
