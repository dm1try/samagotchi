// The one way a jump into the history shows what it lands on: whatever
// hides +el+ unfolds: a closed <details> around it (a turn's steps block, a
// step, a diff), an answer folded by hand (answer_fold.js: its row follows
// the bubble's class; the jump's unfold isn't saved). Every jump goes through it (claim_link.js
// showClaim, refs.js showRow and so the working set's step tags,
// verdict_card.js "View check"), so a new way to hide history is opened in
// one place.
//
// Pure DOM, so it runs under `node --test` with happy-dom. A module of its
// own: static JS is cached at unversioned URLs, and a new export on an old
// module would blank the page.

// Opens each closed <details> that holds +el+ (not +el+ itself: a fold the
// caller means to open it opens itself) and unfolds the folded answer that
// is or holds it. +el+, or null.
export function revealInHistory(el) {
  if (!el) return null;
  el.closest?.(".bubble.output.folded")?.classList.remove("folded");
  for (let details = el.parentElement?.closest("details"); details; details = details.parentElement?.closest("details")) {
    details.open = true;
  }
  return el;
}
