// A finished turn's pieces beside its block, in the order live left them
// there (turn_block.js drawnTurnNodes builds its extras from it). Live, the
// stage's extras go to the history while the turn is opened there (a docking
// piece opened it: a question asked, a card that asks), each when it stops
// waiting (stage_asking.js settleCards, stage_view.js settleWaiting), and
// the rest at the hand-off, in their order:
// - a reminder or a merged line: where it arrived (it never waits);
// - a question with a lead-in (its step's text became its "said" bubble):
//   at its request, where the lead-in went (stage_opened.js ask);
// - a question without one: at its answer (or its cancel);
// - a card that waited when it arrived (an asking card, a warning): where
//   it stopped waiting (the drawing's part_settled, Bridge::TurnAccumulator
//   #fold_card), while the turn is opened; else at the hand-off. One still
//   waiting at the end goes last (a warning there leaves with the block's
//   kept cards: drawnTurnNodes reads that off the drawn card).
// A card that didn't wait at arrival is a row of its step: not a piece. Its
// arrival wait is the first part_settled's `was` (the drawing keeps the
// card's latest version only), else its event's own; a drawing written
// before settle parts orders its cards by their latest version.
// Pure: no DOM. docs/internals/web-frontend.md (A drawn turn).
import { cardWait } from "./card_kinds.js";

// Whether each question has a lead-in, as cards_place.js
// placeResolvedQuestion decides it on a reload: its step has text, and it
// is that step's first question. @return Map<question id, boolean>
function leadIns(events) {
  const text = new Map();
  let step = 0;
  for (const e of events) {
    if (e?.type === "generation_started") step = Number(e.iteration) || step + 1;
    else if (e?.type === "generation_chunk" && e.text) text.set(step, (text.get(step) || "") + e.text);
  }
  const out = new Map();
  const taken = new Set();
  step = 0;
  for (const e of events) {
    if (e?.type === "generation_started") step = Number(e.iteration) || step + 1;
    if (e?.type !== "question_requested" || e.pending_question?.id == null) continue;
    const has = !taken.has(step) && !!(text.get(step) || "").trim();
    if (has) taken.add(step);
    out.set(String(e.pending_question.id), has);
  }
  return out;
}

// +events+: a drawing's events (chi web's turn_drawings[id].events).
// @return {pieces: [{at, kind: "card" | "question" | "merged" | "reminder", id?}], cards: Set<at>}
//   pieces: in live's order (+at+: its event's index; a question's is its
//   question_requested); cards: the card events that are pieces (the others
//   are rows of their step)
export function settleOrder(events = []) {
  const list = Array.isArray(events) ? events : [];
  const arrival = new Map();
  for (const e of list) {
    if (e?.type === "part_settled" && e.of === "card" && e.id != null && !arrival.has(String(e.id))) arrival.set(String(e.id), e.was || null);
  }
  const lead = leadIns(list);
  const stage = [];
  const out = [];
  const cards = new Map();
  const questions = new Map();
  let opened = false;
  const leave = () => {
    if (!opened) return;
    for (let i = 0; i < stage.length;) {
      if (stage[i].waits) i += 1;
      else out.push(stage.splice(i, 1)[0].piece);
    }
  };
  list.forEach((e, at) => {
    switch (e?.type) {
      case "merged_input": stage.push({ piece: { at, kind: "merged" }, waits: false }); break;
      case "reminder_injected": stage.push({ piece: { at, kind: "reminder" }, waits: false }); break;
      case "card": {
        const id = String(e.id ?? "");
        if (cards.has(id)) break;
        const wait = arrival.has(id) ? arrival.get(id) : cardWait(e, { inTurn: true }).kind;
        if (!wait) break;
        const entry = { piece: { at, kind: "card", id }, waits: true };
        cards.set(id, entry);
        stage.push(entry);
        if (wait === "asks") opened = true;
        break;
      }
      case "part_settled": {
        const entry = e.of === "card" ? cards.get(String(e.id ?? "")) : null;
        if (entry) entry.waits = !!e.now;
        break;
      }
      case "question_requested": {
        const id = e.pending_question?.id;
        if (id == null || questions.has(String(id))) break;
        // The turn opens first (stage_asking.js openTurn: what the extras
        // held goes to the history), then the lead-in goes to the
        // history's end; the answered card lands under it.
        opened = true;
        leave();
        const entry = { piece: { at, kind: "question", id: String(id) }, waits: true };
        questions.set(String(id), entry);
        if (lead.get(String(id))) out.push(entry.piece);
        else stage.push(entry);
        break;
      }
      case "question_answered":
      case "question_cancelled": {
        const entry = questions.get(String(e.id ?? ""));
        if (entry) entry.waits = false;
        break;
      }
      default: break;
    }
    leave();
  });
  // The hand-off: what is still in the stage, in its order.
  out.push(...stage.map((entry) => entry.piece));
  return { pieces: out, cards: new Set([...cards.values()].map((entry) => entry.piece.at)) };
}
