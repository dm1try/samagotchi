// What the model has of one working-set item, as the reader (ws_reader.js)
// and the popover's peek (ws_peek.js) show it: the pure part. No DOM, so
// `node --test` covers it. The server's timeline (GET …/working_set/item,
// WorkingSet.timeline_of: docs/internals/working-set.md, Timeline) is every
// run of the item in conversation order; here it becomes cards, newest
// first:
// - a slice: reads whose lines overlap or touch, merged (each line from the
//   newest read holding it), its header listing the reads; reads merge only
//   with reads in the same state (still sent, dropped, forgotten), so a
//   slice the model no longer has is greyed whole, and only between the same
//   edits or writes (an edit moves the lines after it);
// - a partial read (a head/tail preview, a cut output), shown as it is;
// - an edit or a write, its saved diff (diff_view.js);
// - a memory read (its text, its overlay apart), a memory write, a fetch.
// The file strip draws the merged ranges over the file's length (the
// largest last line any read knows: a whole read's is the file's).
//
// An event's place on the page (its step tag, "go to the call") is the
// item's row with its tool id (working_set.js runs); a legacy row has
// none, so the server's global step names it.

import { stepTag } from "./working_set.js";

// A slice longer than this shows its first lines and a "show all" fold.
export const SLICE_FOLD_LINES = 200;
// The peek's lines of a read or a text.
export const PEEK_LINES = 12;

const STATES = ["sent", "dropped", "forgotten"];

// An event's state: sent, dropped (the user's) or forgotten.
export function eventState(event) {
  if (event?.dropped) return "dropped";
  if (event && event.sent === false) return "forgotten";
  return "sent";
}

// The path of the item route for session +id+ (+now+: a memory's text now).
export function itemPath(id, kind, key, { now = false } = {}) {
  const query = new URLSearchParams({ kind, key });
  if (now) query.set("now", "1");
  return `/api/sessions/${encodeURIComponent(id)}/working_set/item?${query}`;
}

// A read's lines as numbered rows ([{n, text}]), its text split as the
// file's (a last newline ends a line), at most up to its last line.
export function readRows(event) {
  const first = Number(event?.lines?.first) || 1;
  const lines = String(event?.text ?? "").split("\n");
  if (lines.at(-1) === "") lines.pop();
  const last = Number(event?.lines?.last);
  const count = Number.isFinite(last) && last >= first ? Math.min(lines.length, last - first + 1) : lines.length;
  return lines.slice(0, count).map((text, i) => ({ n: first + i, text }));
}

const mergeable = (event) => event.op === "read" && !event.lines?.partial && Number.isFinite(event.lines?.first) && Number.isFinite(event.lines?.last);

// The reads of +events+ merged into slices: [{type: "slice", first, last,
// state, reads, rows, newest}], +newest+ the place of its newest read.
function slices(events) {
  const out = [];
  // An edit or a write starts a new version of the file: its lines move, so
  // only reads between the same edits merge (line numbers are one file's).
  let version = 0;
  const versions = events.map((event) => {
    if (event.op === "edit" || event.op === "write") version += 1;
    return version;
  });
  for (let v = 0; v <= version; v += 1) for (const state of STATES) {
    const reads = events.map((event, place) => ({ event, place }))
      .filter(({ event, place }) => versions[place] === v && mergeable(event) && eventState(event) === state)
      .sort((a, b) => a.event.lines.first - b.event.lines.first || a.place - b.place);
    let open = null;
    for (const read of reads) {
      const { first, last } = read.event.lines;
      if (open && first <= open.last + 1) {
        open.last = Math.max(open.last, last);
        open.reads.push(read);
      } else {
        open = { type: "slice", first, last, state, reads: [read] };
        out.push(open);
      }
    }
  }
  return out.map((slice) => {
    // Each line from the newest read that holds it.
    const lines = new Map();
    for (const { event } of [...slice.reads].sort((a, b) => a.place - b.place)) {
      for (const row of readRows(event)) lines.set(row.n, row.text);
    }
    const rows = [...lines.keys()].sort((a, b) => a - b).map((n) => ({ n, text: lines.get(n) }));
    const reads = slice.reads.sort((a, b) => b.place - a.place).map(({ event }) => event);
    return { ...slice, reads, rows, newest: Math.max(...slice.reads.map((r) => r.place)) };
  });
}

const TYPES = { edit: "edit", write: "edit", memory_read: "memory", memory_write: "written", fetch: "fetch" };

// The timeline's cards, newest first: [{type, newest, ...}] — slices
// (above), and {type: "partial" | "edit" | "memory" | "written" | "fetch",
// event, state}. The newest card is +latest+.
export function timelineCards(events = []) {
  const list = Array.isArray(events) ? events : [];
  const cards = slices(list);
  list.forEach((event, place) => {
    if (event.op === "read" && !mergeable(event)) cards.push({ type: "partial", event, state: eventState(event), newest: place });
    else if (TYPES[event.op]) cards.push({ type: TYPES[event.op], event, state: eventState(event), newest: place });
  });
  cards.sort((a, b) => b.newest - a.newest);
  if (cards.length) cards[0] = { ...cards[0], latest: true };
  return cards;
}

// The file strip: the merged ranges over the file's length (+length+: the
// largest last line known), the newest read's range +latest+.
// @return {length, bands: [{first, last, state, latest?}]} or null without one
export function fileStrip(events = []) {
  const reads = (events || []).filter(mergeable);
  if (!reads.length) return null;
  const length = Math.max(...reads.map((e) => e.lines.last));
  const bands = slices(events).map(({ first, last, state }) => ({ first, last, state }));
  const newest = reads.at(-1);
  bands.push({ first: newest.lines.first, last: newest.lines.last, state: eventState(newest), latest: true });
  return { length, bands };
}

// A band's place on the strip as percentages ({left, width}).
export function bandBox(band, length) {
  const total = Math.max(1, Number(length) || 1);
  const left = ((band.first - 1) / total) * 100;
  const width = Math.max(0.5, ((band.last - band.first + 1) / total) * 100);
  return { left: `${left.toFixed(2)}%`, width: `${Math.min(width, 100 - left).toFixed(2)}%` };
}

// "3 reads, 1 edit" (the peek's link and the reader's head).
export function countsText(events = []) {
  const reads = events.filter((e) => e.op === "read" || e.op === "memory_read" || e.op === "fetch").length;
  const edits = events.filter((e) => e.op === "edit" || e.op === "write" || e.op === "memory_write").length;
  const word = (n, one) => `${n} ${one}${n === 1 ? "" : "s"}`;
  return [reads ? word(reads, "read") : "", edits ? word(edits, "edit") : ""].filter(Boolean).join(", ");
}

// The place of +event+ on the page: its row's at, from the item's runs
// (working_set.js), or null (a legacy row, a row not drawn).
export function placeOf(event, item) {
  const run = (item?.runs || []).find((r) => r.id === event?.tool_id);
  return run ? run.at : null;
}

// An event's step tag: the row's "t3·s14", else the server's "step 14".
export function eventTag(event, item) {
  const at = placeOf(event, item);
  if (at) return stepTag({ at }, { session: true });
  return Number.isFinite(event?.step) ? `step ${event.step}` : "";
}

// A slice's or a card's steps for its header ("t3·s13, t3·s162").
export function tagsText(events, item) {
  return events.map((event) => eventTag(event, item)).filter(Boolean).join(", ");
}

// A read's lines in words: "lines 204–265", "line 3", "whole file".
export function linesText(lines) {
  if (!lines) return "";
  if (lines.partial) return lines.whole ? "a preview of the file" : `from line ${lines.first}, cut`;
  return lines.first === lines.last ? `line ${lines.first}` : `lines ${lines.first}–${lines.last}`;
}

const NO_LONGER = { dropped: "dropped by you", forgotten: "forgotten" };

// Why chi no longer has a card's text, or "" while it does.
export function goneText(state) {
  return NO_LONGER[state] || "";
}

// What the peek shows of an item: the latest edit's diff when it has one,
// else the newest read's (or text's) first lines; +after+ the newest event
// after the one shown (a read after the edit).
// @return {event, kind: "diff" | "lines" | "text", rows?, after} or null
export function peekOf(events = []) {
  const list = Array.isArray(events) ? events : [];
  if (!list.length) return null;
  const editAt = list.findLastIndex((e) => (e.op === "edit" || e.op === "write") && e.diff);
  if (editAt >= 0) {
    const after = list.slice(editAt + 1).at(-1) || null;
    return { event: list[editAt], kind: "diff", after };
  }
  // An edit without a diff (a no-op) shows nothing: the newest other run.
  const event = list.findLast((e) => e.op !== "edit" && e.op !== "write") || list.at(-1);
  if (event.op === "read") return { event, kind: "lines", rows: readRows(event).slice(0, PEEK_LINES), after: null };
  const rows = String(event.text ?? "").split("\n").slice(0, PEEK_LINES).map((text, i) => ({ n: i + 1, text }));
  return { event, kind: "text", rows, after: null };
}

// What an event is, in a header's words ("edit", "read 236–250", "memory read").
export function eventWords(event) {
  if (!event) return "";
  if (event.op === "read") return `read ${linesText(event.lines).replace(/^lines? /, "")}`.trim();
  return { edit: "edit", write: "write", memory_read: "memory read", memory_write: "memory write", fetch: "fetch" }[event.op] || event.op;
}
