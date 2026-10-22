// The working set's pure parts (web.working_set, the stage view): what a
// turn brought into the model's context, from the tool rows the page
// already has, and how it folds into a few fixed lines. No DOM, so
// `node --test` covers the rules; working_set_rail.js and
// working_set_view.js draw them.
//
// An item is {kind, key, label, ops, at, count, state, path?, url?, ref?,
// preloaded?, muted?}: kind file|memory|url, key what it is (a file's full
// path, a memory's name, a URL), ops the operations on it (read, edit,
// write: a write of a file is an edit), at the first row that brought it in
// as ordinals ({turn, step, row}: the turn's place in the page's turns, the
// generation's in the turn, the row's in the generation; never a row key,
// which differs live and reloaded), count the rows that touched it. A later
// touch unions its ops and bumps its count, never its at: within a turn
// the set is append-only, which keeps the fold stable. state is "live" from
// the rows; the server's projection (GET working_set, :working_set_updated:
// WorkingSet) overlays its state (live, stale, forgotten) and tokens by key
// (overlay), never its at.

export const FLASH_MS = 4000;
// Labels per form: the rail's four lines, the row's and the footprint's
// three, the collapsed head's newest one.
export const BUDGETS = Object.freeze({ rail: 4, row: 3, footprint: 3, head: 1 });
export const GLYPHS = Object.freeze({ file: "", memory: "◆", url: "↗", muted: "◇" });
// A directory label longer than this keeps its last two segments.
const DIR_MAX = 22;

const FILE_OPS = { read: "read", edit: "edit", write: "edit" };
const MEMORY_OPS = { memory_read: "read", memory_write: "write" };

// The names a memory row names: memory_read's title can list several
// ("a,b"; an empty one is an index listing: none), memory_write's is one.
export function memoryNames(title) {
  return String(title || "").split(",").map((name) => name.trim()).filter(Boolean);
}

// The URL in a web_fetch row's params (url="…", Ruby-inspect quoted, cut at
// 80 characters with a "…": the cut URL is kept as is), or null.
export function urlOfParams(params) {
  const m = /(?:^|\s)url="((?:[^"\\]|\\.)*)"?/.exec(String(params || ""));
  if (!m) return null;
  const url = m[1].replace(/\\(.)/g, "$1");
  return url || null;
}

// A URL as a short label: its host, then its last two path segments behind
// "…/" when there are more ("github.com/…/pull/812").
export function urlLabel(url) {
  const text = String(url || "");
  const m = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)([^?#]*)/i.exec(text);
  if (!m) return text;
  const segments = m[2].split("/").filter(Boolean);
  if (segments.length <= 2) return [m[1], ...segments].join("/");
  return `${m[1]}/…/${segments.slice(-2).join("/")}`;
}

function basename(path) {
  const parts = String(path).split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : String(path);
}

function dirOf(path) {
  const parts = String(path).split("/");
  parts.pop();
  return parts.join("/");
}

// A directory as a group's label: its path with a trailing "/" when it
// fits DIR_MAX, else "…/" and its last two segments ("…/web/public/").
export function dirLabel(dir) {
  const clean = String(dir).replace(/\/+$/, "");
  const full = `${clean}/`;
  if (full.length <= DIR_MAX) return full;
  const segments = clean.split("/").filter(Boolean);
  return `…/${segments.slice(-2).join("/")}/`;
}

// What one finished row brings into the set: [{kind, key, op, …}], none
// unless it completed ok.
export function rowEntries(row) {
  if (!row || row.status !== "ok") return [];
  const tool = row.tool;
  if (FILE_OPS[tool]) {
    const path = row.ref?.kind === "file" && row.ref.path ? row.ref.path : row.title;
    if (!path) return [];
    const ref = row.ref?.kind === "file" ? row.ref : null;
    // Shown (and grouped) by the title when it is the path relative to the
    // session's folder (the ref's path is absolute; a cut title starts "…").
    const title = String(row.title || "");
    const rel = title && !title.startsWith("\u2026") && String(path).endsWith(title) ? title : String(path);
    return [{ kind: "file", key: String(path), op: FILE_OPS[tool], path: rel, ref }];
  }
  if (MEMORY_OPS[tool]) {
    return memoryNames(row.title).map((name) => ({ kind: "memory", key: name, op: MEMORY_OPS[tool] }));
  }
  if (tool === "web_fetch") {
    const url = urlOfParams(row.params);
    return url ? [{ kind: "url", key: url, op: "read", url }] : [];
  }
  return [];
}

// A row's read lines ("1–120") when its ref names them.
function linesOf(ref) {
  if (!ref?.line) return "";
  return ref.end_line && ref.end_line !== ref.line ? `${ref.line}–${ref.end_line}` : String(ref.line);
}

function newItem(entry, at) {
  const item = { kind: entry.kind, key: entry.key, label: leafText(entry), ops: [entry.op], at, count: 1, state: "live" };
  if (entry.path) item.path = entry.path;
  if (entry.url) item.url = entry.url;
  if (entry.ref) item.ref = entry.ref;
  const lines = entry.op === "read" ? linesOf(entry.ref) : "";
  if (lines) item.lines = lines;
  return item;
}

function touch(item, op) {
  if (!item.ops.includes(op)) item.ops = [...item.ops, op];
  item.count += 1;
}

// A turn's items ({gens: [{tools: rows}]}, the live turn's model or a
// reloaded turn's steps as gens), in order of first entry; +turnOrdinal+
// is the turn's place in the page's turns.
export function itemsOfTurn(turn, turnOrdinal) {
  const items = [];
  const byKey = new Map();
  (turn?.gens || []).forEach((gen, step) => {
    (gen?.tools || []).forEach((row, rowIndex) => {
      for (const entry of rowEntries(row)) {
        const id = `${entry.kind}:${entry.key}`;
        const found = byKey.get(id);
        if (found) touch(found, entry.op);
        else {
          const item = newItem(entry, { turn: turnOrdinal, step, row: rowIndex });
          byKey.set(id, item);
          items.push(item);
        }
      }
    });
  });
  return items;
}

// The session's set: every turn's items merged (the first entry's at kept,
// ops unioned, counts summed), the preloaded memories first (tag
// "prompt"), the used memories no row explains (a turn without its saved
// rows) after them; the muted memories listed apart, never counted.
// @param turns the finished turns' item lists, in order
// @param live the running turn's items (or none)
export function sessionItems({ turns = [], live = [], preloaded = [], muted = [], used = [] } = {}) {
  const items = [];
  const byKey = new Map();
  for (const name of preloaded || []) {
    if (byKey.has(`memory:${name}`)) continue;
    const item = { kind: "memory", key: name, label: name, ops: [], at: null, count: 0, state: "live", preloaded: true };
    byKey.set(`memory:${name}`, item);
    items.push(item);
  }
  for (const list of [...turns, live || []]) {
    for (const it of list) {
      const id = `${it.kind}:${it.key}`;
      const found = byKey.get(id);
      if (!found) {
        const copy = { ...it, ops: [...it.ops] };
        byKey.set(id, copy);
        items.push(copy);
      } else {
        for (const op of it.ops) if (!found.ops.includes(op)) found.ops = [...found.ops, op];
        found.count += it.count;
        if (!found.at) found.at = it.at;
      }
    }
  }
  for (const name of used || []) {
    if (byKey.has(`memory:${name}`)) continue;
    const item = { kind: "memory", key: name, label: name, ops: ["read"], at: null, count: 0, state: "live" };
    byKey.set(`memory:${name}`, item);
    items.push(item);
  }
  const mutedItems = (muted || []).map((name) => ({ kind: "memory", key: name, label: name, ops: [], at: null, count: 0, state: "live", muted: true }));
  return { items, muted: mutedItems };
}

// ── the server's truth ────────────────────────────────────────────────────

export const STATES = Object.freeze(["live", "stale", "forgotten"]);
const ELLIPSIS = "\u2026";

// The server's items by "kind:key", and its URLs (a cut row key matches one
// by prefix).
function serverIndex(server) {
  const byKey = new Map();
  const urls = [];
  for (const it of server?.items || []) {
    if (!it || !STATES.includes(it.state)) continue;
    byKey.set(`${it.kind}:${it.key}`, it);
    if (it.kind === "url") urls.push(it);
  }
  return { byKey, urls };
}

// The server's item for +item+: files by absolute path (a title fallback
// won't match), memories by name, URLs by the row's key (its params
// preview: cut at 80 characters with a "…", whose head must start the
// server's URL). null when the server doesn't know it (a running call).
function serverItem(index, item) {
  const exact = index.byKey.get(`${item.kind}:${item.key}`);
  if (exact || item.kind !== "url") return exact || null;
  const key = String(item.key);
  if (!key.endsWith(ELLIPSIS)) return null;
  const head = key.slice(0, -1);
  return index.urls.find((it) => String(it.key).startsWith(head)) || null;
}

// +items+ with the server's state and tokens (+server+: a snapshot {items,
// at}, or null); an item it doesn't know stays live, without tokens. New
// objects only where something changed; never touches at, ops or count.
export function overlay(items, server) {
  if (!server) return items;
  const index = serverIndex(server);
  return items.map((item) => {
    const found = serverItem(index, item);
    const state = found ? found.state : "live";
    const tokens = found && Number.isFinite(found.tokens) ? found.tokens : undefined;
    if (item.state === state && item.tokens === tokens) return item;
    const next = { ...item, state };
    if (tokens === undefined) delete next.tokens;
    else next.tokens = tokens;
    return next;
  });
}

// Which snapshot to keep: +next+ when there is none yet or it is built from
// as much of the conversation as the kept one (its at), else +kept+. A GET
// that answered after a newer event never wins over it.
export function newerSnapshot(kept, next) {
  if (!next || !Array.isArray(next.items) || !Number.isFinite(next.at)) return kept;
  if (!kept || next.at >= kept.at) return next;
  return kept;
}

// Tokens as the popover shows them: "~840", "~1.2k", "~12k".
export function tokensText(tokens) {
  if (!Number.isFinite(tokens)) return "";
  if (tokens < 1000) return `~${Math.round(tokens)}`;
  const k = tokens / 1000;
  return `~${k < 10 ? String(Math.round(k * 10) / 10).replace(/\.0$/, "") : Math.round(k)}k`;
}

const isForgotten = (item) => item.state === "forgotten";
const isFaded = (item) => item.state === "stale" || item.state === "forgotten";

// A group's state: forgotten when all its members are, stale when all are
// stale or forgotten, else live (spec §3: struck only when all forgotten,
// faded when all stale or forgotten).
export function groupState(members) {
  if (members.length && members.every(isForgotten)) return "forgotten";
  if (members.length && members.every(isFaded)) return "stale";
  return "live";
}

function edited(item) {
  return item.kind === "file" && item.ops.includes("edit");
}

// A leaf's text: a file's name, a memory's name, a URL's short label.
export function leafText(item) {
  if (item.kind === "file") return basename(item.path || item.key);
  if (item.kind === "url") return urlLabel(item.url || item.key);
  return String(item.key);
}

// ── the fold ──────────────────────────────────────────────────────────────

function leafLabel(item) {
  return {
    id: `${item.kind}:${item.key}`, type: "leaf", kind: item.kind, glyph: GLYPHS[item.kind] || "", text: leafText(item),
    n: 1, edited: edited(item) ? 1 : 0, cut: isForgotten(item) ? 1 : 0, state: item.state || "live", members: [item],
  };
}

function plural(n, word) {
  if (n === 1) return `${n} ${word}`;
  return `${n} ${word === "memory" ? "memories" : `${word}s`}`;
}

const KIND_WORDS = { memory: "memory", url: "url", file: "file" };

// A group spec as a label over +members+ (items, in entry order).
function groupLabel(spec, members) {
  const n = members.length;
  const edits = members.filter(edited).length;
  // The state marks (spec §3): ✂n the forgotten members, the group's own
  // state from all of them.
  const marks = { cut: members.filter(isForgotten).length, state: groupState(members) };
  if (spec.type === "dir") {
    return { id: `dir:${spec.dir}`, type: "dir", kind: "file", glyph: "", text: dirLabel(spec.dir), count: plural(n, "file"), n, edited: edits, ...marks, members, dir: spec.dir };
  }
  if (spec.type === "kind") {
    return { id: `kind:${spec.of}`, type: "kind", kind: spec.of, glyph: GLYPHS[spec.of], text: plural(n, KIND_WORDS[spec.of]), n, edited: 0, ...marks, members };
  }
  const dirs = new Set(members.map((m) => dirOf(m.path || m.key)));
  return { id: "files", type: "files", kind: "file", glyph: "", text: `${plural(n, "file")} · ${plural(dirs.size, "dir")}`, n, edited: edits, ...marks, members };
}

// Whether label +l+ belongs to group +spec+.
function belongs(l, spec) {
  if (spec.type === "dir") return l.type === "leaf" && l.kind === "file" && (l.members[0].path || l.members[0].key).startsWith(`${spec.dir}/`);
  if (spec.type === "kind") return l.type === "leaf" && l.kind === spec.of;
  return l.kind === "file" && (l.type === "leaf" || l.type === "dir");
}

// +labels+ with +spec+'s members folded into one label at the first one's
// slot, or null when it would hold fewer than +least+.
function applyGroup(labels, spec, least = 2) {
  const at = [];
  labels.forEach((l, i) => { if (belongs(l, spec)) at.push(i); });
  if (at.length < least) return null;
  const members = at.flatMap((i) => labels[i].members);
  const group = groupLabel(spec, members);
  const out = [];
  labels.forEach((l, i) => {
    if (i === at[0]) out.push(group);
    else if (!at.includes(i)) out.push(l);
  });
  return out;
}

// The folders, in order: each looks at the labels and names the group it
// would fold, or null. Later rules are new entries here, not loop changes.
function byDirectory(labels) {
  const counts = new Map();
  for (const l of labels) {
    if (l.type !== "leaf" || l.kind !== "file") continue;
    const parts = String(l.members[0].path || l.members[0].key).split("/");
    parts.pop();
    for (let d = parts.length; d > 0; d -= 1) {
      const dir = parts.slice(0, d).join("/");
      if (!dir) continue;
      counts.set(dir, (counts.get(dir) || 0) + 1);
    }
  }
  // The deepest directory holding two or more (ties: the one holding more,
  // then the earlier), so web/public/ and lib/samagotchi/llm/ fold apart
  // instead of into lib/samagotchi/.
  let best = null;
  for (const [dir, n] of counts) {
    if (n < 2) continue;
    const depth = dir.split("/").length;
    if (!best || depth > best.depth || (depth === best.depth && n > best.n)) best = { dir, depth, n };
  }
  return best ? { type: "dir", dir: best.dir } : null;
}

function byKind(labels) {
  for (const of of ["memory", "url"]) {
    if (labels.filter((l) => l.type === "leaf" && l.kind === of).length >= 2) return { type: "kind", of };
  }
  return null;
}

function lastResort(labels) {
  return labels.filter((l) => l.kind === "file" && (l.type === "leaf" || l.type === "dir")).length >= 2 ? { type: "files" } : null;
}

const FOLDERS = [byDirectory, byKind, lastResort];

function specKey(spec) {
  return spec.type === "dir" ? `dir:${spec.dir}` : spec.type === "kind" ? `kind:${spec.of}` : "files";
}

// +items+ (in entry order) as at most +budget+ labels: leaves while they
// fit, else the folders' groups, each at its first member's slot. +kept+:
// the groups an earlier fold of the same set made (its +groups+): applied
// first, so a group once folded stays (the set only grows). +lastResort+:
// false leaves the "N files · K dirs" rule out (the footprint's tails say
// the rest instead). @return {labels, groups}
export function fold(items, budget, { kept = [], lastResort: useLast = true } = {}) {
  let labels = items.map(leafLabel);
  const groups = [];
  const done = new Set();
  for (const spec of kept) {
    if (done.has(specKey(spec))) continue;
    const next = applyGroup(labels, spec, 1);
    if (next) {
      labels = next;
      groups.push(spec);
      done.add(specKey(spec));
    }
  }
  const folders = useLast ? FOLDERS : FOLDERS.filter((f) => f !== lastResort);
  while (labels.length > budget) {
    const spec = folders.map((f) => f(labels)).find(Boolean);
    const next = spec && applyGroup(labels, spec);
    if (!next) break;
    labels = next;
    groups.push(spec);
  }
  return { labels, groups };
}

// The labels a form shows for +budget+: all of them when they fit, else
// the first budget − 1 and how many members the rest hold (its "+ n more").
export function shown(labels, budget) {
  if (labels.length <= budget) return { labels, more: 0 };
  const head = labels.slice(0, Math.max(0, budget - 1));
  return { labels: head, more: labels.slice(head.length).reduce((n, l) => n + l.n, 0) };
}

// A label's hover: its members, one per line ("path ✎").
export function labelTitle(label) {
  return label.members.map((m) => `${m.kind === "file" ? (m.path || m.key) : m.kind === "url" ? (m.url || m.key) : m.key}${edited(m) ? " ✎" : ""}${isFaded(m) ? ` (${m.state})` : ""}`).join("\n");
}

// ── tags, texts ───────────────────────────────────────────────────────────

// Where an item entered: "s3" (step 3 of its turn), "t2·s3" in the
// session's scope, "prompt" for a preloaded memory, "" when unknown.
export function stepTag(item, { session = false } = {}) {
  if (item?.preloaded) return "prompt";
  const at = item?.at;
  if (!at) return "";
  return session ? `t${at.turn + 1}·s${at.step + 1}` : `s${at.step + 1}`;
}

// A group's steps as a range ("s1–5"), or its one step ("s2").
export function stepRange(members) {
  const steps = [...new Set(members.filter((m) => m.at).map((m) => m.at.step + 1))].sort((a, b) => a - b);
  if (!steps.length) return "";
  return steps.length === 1 ? `s${steps[0]}` : `s${steps[0]}–${steps[steps.length - 1]}`;
}

// What was done to an item, in the expanded view's words.
export function opsText(item) {
  if (item.muted) return "muted (--mute)";
  if (item.preloaded) return item.ops.length ? "preloaded, read" : "preloaded";
  const words = [];
  if (item.ops.includes("read")) {
    const reads = item.ops.length === 1 && item.count > 1 ? ` ×${item.count}` : item.lines ? ` ${item.lines}` : "";
    words.push(item.kind === "url" ? "fetched" : `read${reads}`);
  }
  if (item.ops.includes("edit")) words.push(item.ops.length === 1 && item.count > 1 ? `edited ×${item.count}` : "edited");
  if (item.ops.includes("write")) words.push("written");
  const text = words.join(", ");
  // The state in words (colour is never alone): "read 1–120 · stale".
  return isFaded(item) ? [text, item.state].filter(Boolean).join(" · ") : text;
}

// A label as the screen reader says it ("web/public 9 files 2 edited").
function spoken(label) {
  if (label.type === "dir") return `${label.text.replace(/^…\//, "").replace(/\/$/, "")} ${label.count}${label.edited ? ` ${label.edited} edited` : ""}${label.cut ? ` ${label.cut} forgotten` : ""}`;
  if (label.type === "leaf") return `${label.kind === "memory" ? "memory " : label.kind === "url" ? "url " : ""}${label.text}${label.edited ? " edited" : ""}${label.state && label.state !== "live" ? ` ${label.state}` : ""}`;
  return `${label.text}${label.cut ? ` ${label.cut} forgotten` : ""}`;
}

// The rail's (or row's, footprint's) aria-label: the folded text spoken.
export function ariaLabel(labels, more = 0) {
  if (!labels.length) return "Working set: nothing yet. Open the list.";
  return `Working set: ${labels.map(spoken).join(", ")}${more ? `, and ${more} more` : ""}. Open the list.`;
}

// The footprint's pieces for a finished turn's +items+: its labels (at
// most +budget+, no last resort), the rest as one tail ("+1 url", "+3
// more"), and how many files it edited. null for a turn that touched
// nothing (no line).
export function footprint(items, budget = BUDGETS.footprint) {
  if (!items.length) return null;
  const { labels } = fold(items, budget, { lastResort: false });
  const head = labels.slice(0, budget);
  const rest = labels.slice(budget).flatMap((l) => l.members);
  let tail = "";
  if (rest.length) {
    const kinds = new Set(rest.map((m) => m.kind));
    tail = kinds.size === 1 ? `+${plural(rest.length, KIND_WORDS[[...kinds][0]])}` : `+${rest.length} more`;
  }
  return { labels: head, tail, edited: items.filter(edited).length, forgotten: items.filter(isForgotten).length };
}

// A label's text as the footprint and the row draw it: its glyph, text,
// count ("web/public/ · 9 files").
export function labelText(label) {
  const glyph = label.glyph ? `${label.glyph} ` : "";
  return `${glyph}${label.text}${label.count ? ` · ${label.count}` : ""}`;
}

// The footprint as plain text (its title, the specs): "touched web/public/
// · 9 files · ◆ 3 memories s1–5 · +1 url · edited 2".
export function footprintText(items, budget = BUDGETS.footprint) {
  const fp = footprint(items, budget);
  if (!fp) return "";
  const parts = fp.labels.map((l) => {
    const tag = l.kind === "memory" ? (l.type === "leaf" ? stepTag(l.members[0]) : stepRange(l.members)) : "";
    return `${labelText(l)}${tag ? ` ${tag}` : ""}`;
  });
  if (fp.tail) parts.push(fp.tail);
  if (fp.edited) parts.push(`edited ${fp.edited}`);
  if (fp.forgotten) parts.push(`${fp.forgotten} forgotten`);
  return `touched ${parts.join(" · ")}`;
}

// ── the fresh cue ─────────────────────────────────────────────────────────

// An item seen first at +seenAt+ (ms) is fresh until FLASH_MS after it.
export function isFresh(seenAt, now, ms = FLASH_MS) {
  return Number.isFinite(seenAt) && now - seenAt < ms;
}

// How long until the next fresh cue ends (ms), null when none is on.
export function nextSettle(seenTimes, now, ms = FLASH_MS) {
  let next = null;
  for (const t of seenTimes) {
    if (!isFresh(t, now, ms)) continue;
    const left = t + ms - now;
    if (next === null || left < next) next = left;
  }
  return next;
}
