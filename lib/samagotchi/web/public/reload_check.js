// The opt-in reload check (web.reload_check; <body data-reload-check="1">):
// once a finished turn's pieces have reached the history (the stage's
// hand-off), the page reads the session again as a reload would, draws the
// turn offscreen (turnHistoryNodes, a reload's renderer) and compares the
// two (history_shape.js) strictly: no ACCEPTED entry excuses a difference,
// so `same` is false for a known divergence too, and `excused` names the
// entries that would explain the differences (`explained`: all of them
// have one), so chi web's log counts each class apart (the bugs turn
// drawings close, the deliberate ones). It posts the counts, never
// content: {turn_id, same, kinds, excused, explained, drawn}; chi web logs
// them (reload_checked, reload_mismatch). Fire-and-forget: no toast, no
// store write, a failure is dropped.
//
// Cards are left out on both sides: a reload places them after the render
// (CardStore's stamps, cards_place.js), which the offscreen render doesn't
// run; the e2e reload checks compare them.
import { compareShapes, historyShape } from "./history_shape.js";
import { turnElements } from "./turn_range.js";

// The opening of a turn: its prompt, a wake's note, /continue no's line.
const OPENING = "[data-turn-id], [data-opening-id]";
// Not the turn's: the lines queued for after it (they open the next turns).
const NOT_THE_TURNS = ".bubble.user.queued, .bubble.command.queued";

function openingId(el) {
  return el?.dataset?.turnId || el?.dataset?.openingId || null;
}

function withoutCards(shape) {
  return shape.filter((item) => item.kind !== "card");
}

// @param enabled () => whether the check is on (the body's attribute)
// @param sessionId () => the open session's id
// @param running () => whether a turn runs now (liveTurn.running: a queued
//   turn started streaming)
// @param read (id) => the session as a reload reads it (GET ?parts=1)
// @param render (data) => that read drawn as a reload draws it (a fragment)
// @param post (id, body) => the counts to chi web
export function createReloadCheck({ enabled, sessionId, running, read, render, post }) {
  // The hand-off's pieces (stage_view.js onHandedOff), in their order;
  // +immediate+: another turn took the stage at once.
  async function handedOff({ pieces = [], immediate = false } = {}) {
    if (!enabled() || immediate || running()) return;
    const [opening, ...rest] = pieces;
    const turnId = openingId(opening?.matches?.(OPENING) ? opening : null);
    if (!turnId) return;
    const id = sessionId();
    const live = withoutCards(historyShape(rest.filter((el) => !el.matches?.(NOT_THE_TURNS))));
    try {
      const data = await read(id);
      if (sessionId() !== id || running()) return;
      const holder = document.createElement("div");
      holder.append(render(data));
      const reopened = [...holder.querySelectorAll(OPENING)].find((el) => openingId(el) === turnId);
      const reloaded = reopened ? withoutCards(historyShape(turnElements(reopened, { container: holder }))) : [];
      const { same, kinds, excused, explained } = reopened ? compareShapes(live, reloaded)
        : { same: false, kinds: ["prompt"], excused: [], explained: false };
      // Whether the read had a drawing for the turn (turn drawings, P2).
      const drawn = !!data?.turn_drawings?.[turnId];
      await post(id, { turn_id: turnId, same, kinds, excused, explained, drawn });
    } catch (_) {
      // Fire-and-forget: a failed read or post is no finding.
    }
  }
  return { handedOff };
}
