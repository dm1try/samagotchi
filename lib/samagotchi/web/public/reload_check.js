// The opt-in reload check (web.reload_check; <body data-reload-check="1">):
// once a finished turn's pieces have reached the history (the stage's
// hand-off), the page reads the session again as a reload would, draws the
// turn offscreen (turnHistoryNodes, a reload's renderer) and compares the
// two (history_shape.js) strictly: no ACCEPTED entry excuses a difference,
// so `same` is false for a known divergence too, and `excused` names the
// entries that would explain the differences (`explained`: all of them
// have one), so chi web's log counts each class apart (the bugs turn
// drawings close, the deliberate ones). It posts the counts, never
// content: {turn_id, same, kinds, excused, explained, drawn, undrawn} (and
// cards_compared: false when the page passed no card registry); chi
// web logs them (reload_checked, reload_mismatch). `undrawn`: how many rows
// of the reload came without their turn's drawing (turn_block.js's plain
// fallback, data-undrawn): 0 unless chi web missed one. Fire-and-forget: no toast, no
// store write, a failure is dropped.
//
// Compared apart: the turn's cards and questions, as data. The page's
// registry (card_registry.js, fed by the stream) against one seeded from the
// read: the entries of this turn (of_turn) on both sides, equal on key,
// kind, status and summary (not body, buttons, fold or the tag a card is
// drawn in). A difference adds "card" or "question" to +kinds+ (the same
// body: chi web's KINDS has both). CardStore keeps the newest
// CARD_STORE_CAP cards and questions together: a read that lists that many
// may have lost an older one, so a key live has and such a read hasn't is
// no difference. A question the read attributes to no turn and stamps to no
// opening (an older worker) leaves the questions out of it. The history's
// compare drops the card and question items on both sides (their place in
// a finished turn is stage_cuts_parity.test.js's turn-end cut and the e2e's
// reload checks now); it keeps notices, hook notices and guardrail
// warnings. Between-turn cards and notices are out of scope (the e2e
// reload checks cover them).
import { compareShapes, historyShape } from "./history_shape.js";
import { turnElements } from "./turn_range.js";
import { createCardRegistry } from "./card_registry.js";
import { measured, probing } from "./stage_probe.js";
// The opening of a turn (the stage's hand-off reads it too).
import { OPENING } from "./stage_handoff.js";
// Not the turn's: the lines queued for after it (they open the next turns).
const NOT_THE_TURNS = ".bubble.user.queued, .bubble.command.queued";
// Bridge::CardStore::CAPACITY: the cards and questions a read lists at most
// (spec/web/reload_check_route_spec.rb reads it).
const CARD_STORE_CAP = 20;

function openingId(el) {
  return el?.dataset?.turnId || el?.dataset?.openingId || null;
}

// A question the read attributes to no turn (an older worker: no of_turn, and
// no opening it came after, or one stamped to this very turn): the registry
// can't say whose it is, so the questions are left out of the compare. Only
// entries that could belong to this turn count: one stamped to another turn
// does not silence questions here.
function looseQuestions(cards, turnId) {
  return (Array.isArray(cards) ? cards : []).some((entry) => entry?.type === "question"
    && entry?.of_turn == null && (entry?.opening_id == null || String(entry.opening_id) === String(turnId)));
}

// Whether CardStore's cap may have pushed one of this turn's entries out of
// +cards+ (the read's listing).
function capped(cards) {
  return (Array.isArray(cards) ? cards : []).filter((entry) => entry?.type === "card" || entry?.type === "question").length >= CARD_STORE_CAP;
}

// The kinds ("card", "question") in which the turn's entries live and in the
// read differ.
function cardKinds(live, reloaded, { capped: lossy, questions }) {
  const kinds = new Set();
  const kindOf = (key) => (key.startsWith("q:") ? "question" : "card");
  const mine = (list) => new Map(list.filter((e) => questions || !e.key.startsWith("q:")).map((e) => [e.key, e]));
  const a = mine(live);
  const b = mine(reloaded);
  for (const [key, e] of a) {
    const r = b.get(key);
    if (!r) {
      if (!lossy) kinds.add(kindOf(key));
      continue;
    }
    if (["kind", "status", "summary"].some((f) => e[f] !== r[f])) kinds.add(kindOf(key));
  }
  for (const key of b.keys()) if (!a.has(key)) kinds.add(kindOf(key));
  return [...kinds];
}

const NOT_CARDS = (item) => item.kind !== "card" && item.kind !== "question";

// @param enabled () => whether the check is on (the body's attribute)
// @param sessionId () => the open session's id
// @param running () => whether a turn runs now (liveTurn.running: a queued
//   turn started streaming)
// @param read (id) => the session as a reload reads it (the full GET)
// @param render (data) => that read drawn as a reload draws it (a fragment)
// @param cards () => the page's card registry (card_registry.js); without
//   it, the cards and questions are left out
// @param place unused: an older app.js passes cards_offscreen.js's placer
// @param capabilities () => the page's capabilities (unused now; an older
//   app.js passes it)
// @param post (id, body) => the counts to chi web
export function createReloadCheck({ enabled, sessionId, running, read, render, cards = null, post }) {
  // The hand-off's pieces (stage_view.js onHandedOff), in their order;
  // +immediate+: another turn took the stage at once.
  async function handedOff({ pieces = [], immediate = false } = {}) {
    if (!enabled() || immediate || running()) return;
    const [opening, ...rest] = pieces;
    const turnId = openingId(opening?.matches?.(OPENING) ? opening : null);
    if (!turnId) return;
    const id = sessionId();
    const handedAt = performance.now();
    try {
      const data = await read(id);
      if (sessionId() !== id || running()) return;
      // The perf probe (stage_probe.js): the compare's own time, and the
      // hand-off to the post.
      const body = measured("reload:compare", () => compare(data, rest, turnId));
      await post(id, body);
      if (probing()) performance.measure("reload:posted", { start: handedAt, end: performance.now() });
    } catch (_) {
      // Fire-and-forget: a failed read or post is no finding.
    }
  }

  // The counts for the turn +turnId+: the live pieces (+rest+, after its
  // opening) against +data+, the read.
  function compare(data, rest, turnId) {
    // The live pieces as they read now, after the read: a canceled or
    // failed turn hands off at once, and its timing line takes the turn
    // record's figure when its own re-read lands (refreshTimingFromSession),
    // which started at the turn's end, before this one.
    // Whether the read had a drawing for the turn (turn drawings, P2).
    const drawn = !!data?.turn_drawings?.[turnId];
    const live = historyShape(rest.filter((el) => !el.matches?.(NOT_THE_TURNS))).filter(NOT_CARDS);
    const holder = document.createElement("div");
    holder.append(render(data));
    const reopened = [...holder.querySelectorAll(OPENING)].find((el) => openingId(el) === turnId);
    const reloaded = reopened ? historyShape(turnElements(reopened, { container: holder })).filter(NOT_CARDS) : [];
    const verdict = reopened ? compareShapes(live, reloaded)
      : { same: false, kinds: ["prompt"], excused: [], explained: false };
    const registry = cards?.();
    const cardsDiffer = registry ? cardKinds(registry.forTurn(turnId), createCardRegistry().seed(data).forTurn(turnId),
      { capped: capped(data?.cards), questions: !looseQuestions(data?.cards, turnId) }) : [];
    const kinds = [...verdict.kinds, ...cardsDiffer.filter((k) => !verdict.kinds.includes(k))];
    const same = verdict.same && !cardsDiffer.length;
    const explained = verdict.explained && !cardsDiffer.length;
    const undrawn = holder.querySelectorAll("[data-undrawn]").length;
    // No registry (a stale app.js): cards and questions went unchecked, so
    // a "same" is the history's alone.
    return { turn_id: turnId, same, kinds, excused: verdict.excused, explained, drawn, undrawn, ...(registry ? {} : { cards_compared: false }) };
  }
  return { handedOff };
}
