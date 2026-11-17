// The working set's head view (docs/internals/working-set.md, The head
// view): the popover's list as what is in chi's head, in three sections.
//   start  From the start: the system prompt's parts (the session's
//          prompt_parts), in prompt order, the tools part first. A memory
//          part (identity, a model note, a preload) IS a memory row: merged
//          with the session set's row of that name when there is one (a
//          preloaded `system/x` and a part's `x` are one row), else a row of
//          its own (identity: the set never lists it). Other parts are
//          `part` rows: a label, a sub, their tokens, no actions.
//   read   Read in this session: today's files / memories / urls sections
//          (working_set.js bodySections), minus the memories shown in start.
//   talk   Conversation: one row (drawn at section level, no header, no
//          fold), the rest of the context: the context's
//          tokens minus the parts' and the held items'. Mixed units (parts and
//          items are chars/4, the context's the server's count or the
//          calibrated estimate): the "~" says so.
// No parts (an old session or worker, a participant): none of this, the
// list is today's (headSections returns null).
//
// No DOM: `node --test` covers the rules; working_set_view.js draws them.
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { bodySections, itemKey, tokensText } from "./working_set.js";

// The sections folded by hand, per session (session_prefs.js): a JSON list
// of section keys. None: all open.
export const WS_SECTION_FOLD = "chi_ws_sections_folded";

export const MEMORY_PARTS = Object.freeze(["identity", "notes", "preloads"]);

// What a memory part's row says it is.
const MEMORY_WORDS = { identity: "identity memory", notes: "model note", preloads: "preloaded" };
// A part row's sub text, by kind (the tools part's is its label, "31 declared").
const PART_SUBS = { agents: "project instructions", appended: "appended", plugins: "plugin section" };

// A memory's name as memory_read takes it: a leading project/ or system/
// scope is not part of it.
export function memoryName(name) {
  const m = /^(project|system)\/(.+)$/.exec(String(name || "").trim());
  return m ? m[2] : String(name || "").trim();
}

const struck = (item) => item.state === "forgotten" || item.state === "dropped";
const held = (item) => !item.muted && !item.added && !struck(item);
const sum = (list, of) => list.reduce((n, x) => n + (Number.isFinite(of(x)) ? of(x) : 0), 0);

// A part's row: never an item the set or a steer line knows.
function partRow(part, key) {
  const tools = part.kind === "tools";
  return {
    kind: "part", key, partKind: part.kind, label: tools ? "tools" : String(part.label || part.kind),
    sub: tools ? String(part.label || "") : PART_SUBS[part.kind] || "", partTokens: Number.isFinite(part.tokens) ? part.tokens : 0,
    ops: [], at: null, count: 0, state: "live",
  };
}

// A memory part's row: the set's rows of that name merged (its read one
// first: its tokens, its key for steering), or one of its own.
function memoryRow(part, name, matches) {
  const main = matches.find((m) => m.ops.includes("read")) || matches[0];
  const base = main ? { ...main } : { kind: "memory", key: name, label: name, ops: [], at: null, count: 0, state: "live" };
  const ops = [...new Set(matches.flatMap((m) => m.ops))];
  const at = matches.map((m) => m.at).find(Boolean) || base.at || null;
  return {
    ...base, ops, at, label: name, preloaded: true, partKind: part.kind, partTokens: Number.isFinite(part.tokens) ? part.tokens : 0,
    mergedKeys: matches.map(itemKey),
  };
}

// A start memory row's read still sent (read, not forgotten or dropped):
// what "held twice", its "+X" and the conversation's arithmetic count.
const readHeld = (row) => row.kind === "memory" && !!row.partKind && row.ops.includes("read") && !struck(row);

// Whether a start memory row is in the prompt and its read is held too.
export const heldTwice = (row) => readHeld(row);

// A start memory row's words: what it is in the prompt (a read again is
// its "held twice" tag, or the turn lens's note).
export const memoryPartWords = (row) => MEMORY_WORDS[row.partKind] || "in the prompt";

// The keys of the set's items a start memory row stands for: never new to
// the head in a turn lens (the prompt had them from the start).
export function promptKeys(sections) {
  return new Set((sections?.find((s) => s.key === "start")?.rows || []).flatMap((r) => r.mergedKeys || []));
}

// A start row's tokens: the part's, and "+X" for a memory's read (its item
// tokens: a preloaded row carries none of its own, so the two never
// double-count). "~0.6k +0.4k".
export function startTokensText(row) {
  const own = tokensText(row.partTokens);
  if (!readHeld(row) || !Number.isFinite(row.tokens)) return own;
  return `${own} +${tokensText(row.tokens).replace(/^~/, "")}`;
}

// The held-twice note under a start memory row in a turn lens whose items
// read it: "read again in this turn: already in the prompt, held twice (+X)".
export function heldTwiceNote(row, turnItem) {
  if (!readHeld(row) || !turnItem?.ops?.includes("read")) return "";
  const extra = Number.isFinite(row.tokens) ? ` (+${tokensText(row.tokens).replace(/^~/, "")})` : "";
  return `read again in this turn: already in the prompt, held twice${extra}`;
}

// The head view's sections for +set+ ({items, muted}: the session's set,
// overlaid), or null without parts (today's list). +parts+: the session's
// prompt_parts; +ctxTokens+: the context's tokens now (null: unknown);
// +turns+: how many turns the session has (the conversation row's).
// @return [{key, title, meta, tokens, rows?, inner?}] start, read, talk?
export function headSections(set, budget, { parts = null, ctxTokens = null, turns = 0, inTurn = false } = {}) {
  if (!Array.isArray(parts) || !parts.length) return null;
  const used = new Set();
  const byName = new Map();
  for (const item of set.items) {
    if (item.kind !== "memory") continue;
    const name = memoryName(item.key);
    byName.set(name, [...(byName.get(name) || []), item]);
  }
  const rows = [];
  const keys = new Set();
  const seenMemory = new Map();
  for (const part of parts) {
    if (!part || !part.kind) continue;
    if (MEMORY_PARTS.includes(part.kind) && part.ref) {
      const name = memoryName(part.ref);
      const again = seenMemory.get(name);
      // A memory in two parts (a note also preloaded): one row, both sizes.
      if (again) {
        again.partTokens += Number.isFinite(part.tokens) ? part.tokens : 0;
        continue;
      }
      const matches = byName.get(name) || [];
      matches.forEach((m) => used.add(itemKey(m)));
      const row = memoryRow(part, name, matches);
      seenMemory.set(name, row);
      keys.add(itemKey(row));
      rows.push(row);
      continue;
    }
    let key = `${part.kind}:${part.ref ?? part.label ?? ""}`;
    for (let n = 2; keys.has(`part:${key}`); n += 1) key = `${part.kind}:${part.ref ?? part.label ?? ""}#${n}`;
    keys.add(`part:${key}`);
    rows.push(partRow(part, key));
  }
  const partsTokens = sum(rows, (r) => r.partTokens);
  // A preloaded memory never read is the prompt's, never "read in this
  // session": one no part names (a ref-less preloads / notes part, whose
  // items' sizes didn't line up; a preload that failed to load) stays out.
  const rest = { items: set.items.filter((item) => !used.has(itemKey(item)) && !(item.preloaded && !item.ops.includes("read"))), muted: set.muted };
  const readItems = rest.items;
  const out = readItems.filter(struck).length;
  // The read section's tokens: its held items'; the start rows' reads count
  // into the conversation's arithmetic, not into either section.
  const readTokens = sum(readItems.filter(held), (i) => i.tokens);
  const heldTokens = readTokens + sum(rows.filter(readHeld), (r) => r.tokens);
  const sections = [
    { key: "start", title: "From the start", meta: inTurn ? "in every turn" : `${rows.length} part${rows.length === 1 ? "" : "s"} · in every turn`, tokens: partsTokens, rows },
    {
      key: "read", title: "Read in this session", meta: [`${readItems.filter(held).length} held`, out ? `${out} out` : ""].filter(Boolean).join(" · "),
      tokens: readTokens, inner: bodySections(rest, budget),
    },
  ];
  const talk = Number.isFinite(ctxTokens) ? ctxTokens - partsTokens - heldTokens : NaN;
  if (talk > 0) {
    const row = { kind: "talk", key: "conversation", label: "conversation", sub: `${turns} turn${turns === 1 ? "" : "s"}`, partTokens: talk, ops: [], at: null, count: 0, state: "live" };
    sections.push({ key: "talk", title: "Conversation", meta: "", tokens: talk, rows: [row] });
  }
  return sections;
}

// +touched+ (a turn lens: the turn's items by key) with each start memory
// row's merged keys under its own key, so a read of `system/x` lights the
// row of `x` (the set holds both spellings). The map given is not changed.
export function lensTouched(sections, touched) {
  if (!touched || !sections) return touched;
  const out = new Map(touched);
  for (const row of sections.find((s) => s.key === "start")?.rows || []) {
    if (!row.mergedKeys || out.has(itemKey(row))) continue;
    const hit = row.mergedKeys.find((k) => touched.has(k));
    if (hit) out.set(itemKey(row), touched.get(hit));
  }
  return out;
}

// The section keys folded, from the stored value (a JSON list); unreadable: none.
// Conversation never folds (one row): an older page's stored "talk" is ignored.
export function foldedSections(stored) {
  try {
    const list = JSON.parse(stored || "[]");
    return new Set(Array.isArray(list) ? list.filter((k) => typeof k === "string" && k !== "talk") : []);
  } catch (_) {
    return new Set();
  }
}

// The head line in the session lens: "in chi's head now · ~X of Y" (Y the
// window; no "of Y" when unknown), "" without the context's tokens.
export function headLine(ctxTokens, windowTokens) {
  if (!Number.isFinite(ctxTokens)) return "";
  const of = Number.isFinite(windowTokens) && windowTokens > 0 ? ` of ${tokensText(windowTokens).replace(/^~/, "")}` : "";
  return `in chi's head now · ${tokensText(ctxTokens)}${of}`;
}
