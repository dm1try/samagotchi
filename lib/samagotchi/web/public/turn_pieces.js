// A finished turn's pieces in one order, and which step's text is its
// answer: the one rule the live hand-off (stage_model.js handOffOrder, the
// turn block's turnEnded) and a reload (turn_block.js turnHistoryNodes)
// both follow, so the two can't place a piece differently. Pure: the pieces
// are whatever the caller draws (nodes, lit templates); a missing one is
// skipped.

// The turn's pieces in order: its prompt (none for a reminder turn), its
// block of steps, the steers no step holds, the lines merged into it in
// arrival order (live: every extra, cards too), the answer's pieces or the
// notice of a turn with none, the timing line, a participant's review Apply,
// the end line (cancel, failure), the kept cards, then the lines queued for
// after the turn (they run next).
export function turnPieces({ prompt = null, block = null, steers = [], merged = [], answer = [], emptyNote = null, timing = null,
  apply = null, end = null, kept = [], queued = [] } = {}) {
  return [prompt, block, ...steers, ...merged, ...answer, emptyNote, timing, apply, end, ...kept, ...queued].filter(Boolean);
}

// The generation whose text is +turn+'s answer when it ended as +kind+
// ("completed", "canceled", "failed"), else null: its current (last, still
// open) generation, for a completed turn always, for any turn of one step
// without tools too (canceled, it is the partial text). +turn+: turn_model.js's
// {gens: [{tools, closed}]}.
export function answerGen(turn, kind) {
  const gens = turn?.gens || [];
  const last = gens[gens.length - 1];
  if (!last || last.closed) return null;
  return kind === "completed" || (gens.length === 1 && last.tools.length === 0) ? last : null;
}
