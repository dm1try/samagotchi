// A turn's elements in the history, as the page groups them: the siblings
// after its opening ([data-turn-id], the prompt bubble) up to the next
// opening, or a context note before it (a wake turn starts with one, and
// its bubble carries no turn id: what follows it isn't the turn before's).
// A gap divider just before that end belongs to the next group. One rule
// for every walker of a turn (verdict_card.js, verify_target.js).
//
// Pure DOM reads, so it runs under `node --test` with happy-dom. A module of
// its own: static JS is cached at unversioned URLs, and a new export on an
// old module would blank the page.

// The owner's page: a context note ends a turn. The participant page has
// none (its rule passes null).
export const NOTE_BOUNDARY = ".bubble.note";

// The elements of the turn +opening+ starts (the [data-turn-id] element, or
// one inside it), at +container+'s level (default: the opening's parent),
// in order; a +boundary+ element ends them too. [] when the opening isn't
// in +container+ or its turn has nothing after it.
export function turnElements(opening, { container = opening?.parentElement, boundary = NOTE_BOUNDARY } = {}) {
  let top = opening;
  while (top && top.parentElement !== container) top = top.parentElement;
  if (!top) return [];
  const elements = [];
  for (let next = top.nextElementSibling; next; next = next.nextElementSibling) {
    if (next.matches("[data-turn-id]") || next.querySelector("[data-turn-id]")) break;
    if (boundary && next.matches(boundary)) break;
    elements.push(next);
  }
  while (elements.at(-1)?.classList.contains("time-gap")) elements.pop();
  return elements;
}
