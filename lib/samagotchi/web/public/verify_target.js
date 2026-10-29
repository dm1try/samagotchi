// Where the Verify preset is offered (verify_preset.js), on both pages: only
// on text in an ended turn's final answer, the one place the server takes a
// claim from. Engine#verified_anchor records a Verify turn's card only when
// its quote is in the last answer of the source turn (AnswerTail.answer?:
// the turn's last assistant message with text, from its prompt up to the
// next prompt, merged lines and steers inside); anything else (an earlier
// reply, a step, a person's line, a reply still running) is refused with
// `quote_missing` and the turn runs as a plain comment, no card. So the
// page offers Verify where the server will accept it, and nowhere else.
//
// The turn is the page's own grouping (claim_link.js turnIdOf,
// verdict_card.js turnElements): the last turn opening ([data-turn-id]) at
// or before the selection, and its elements up to the next opening. Its
// final answer is the last of them matching the page's answer selector.
//
// Pure DOM reads (Element, compareDocumentPosition), so it runs under
// `node --test` with happy-dom. A module of its own: static JS is cached at
// unversioned URLs, and a new export on an old module would blank the page.

const PRECEDING = 2;

// The owner's page: an answer bubble (not a delegate report's reply, which
// a turn shows before its answer); a context note ends a turn's elements
// (a wake turn starts with one, and its bubble carries no turn id).
export const OWNER_FINAL = Object.freeze({ answers: ".bubble.output:not(.report-reply)", boundary: ".bubble.note" });
// The participant page: a reply's bubble.
export const PARTICIPANT_FINAL = Object.freeze({ answers: ".p-msg.reply > .p-bubble", boundary: null });

// The turn opening +node+ is in (the last [data-turn-id] at or before it in
// +container+) and whether it is the newest one: {anchor, last}, or null.
function openingOf(container, node) {
  const anchors = [...container.querySelectorAll("[data-turn-id]")];
  let at = -1;
  anchors.forEach((anchor, i) => {
    if (anchor === node || anchor.contains(node) || (node.compareDocumentPosition(anchor) & PRECEDING)) at = i;
  });
  return at < 0 ? null : { anchor: anchors[at], last: at === anchors.length - 1 };
}

// The final answer of the turn whose opening is +anchor+: the last element
// matching +answers+ among the opening's siblings after it, up to the next
// opening or a +boundary+ element. null when it has none.
function finalAnswer(container, anchor, { answers, boundary }) {
  let top = anchor;
  while (top && top.parentElement !== container) top = top.parentElement;
  if (!top) return null;
  let final = null;
  for (let el = top.nextElementSibling; el; el = el.nextElementSibling) {
    if (el.matches("[data-turn-id]") || el.querySelector("[data-turn-id]")) break;
    if (boundary && el.matches(boundary)) break;
    const inside = [...el.querySelectorAll(answers)];
    if (inside.length) final = inside[inside.length - 1];
    else if (el.matches(answers)) final = el;
  }
  return final;
}

// The turn id Verify anchors to for a selection in +root+ (the annotate
// source's root) in +container+, or null where Verify isn't offered: not in
// a turn, not in its final answer, or in the running turn. +rule+:
// OWNER_FINAL or PARTICIPANT_FINAL. +running+: null when no turn runs, else
// {turnId} (the running turn's id; null when unknown, then the newest turn
// counts as the running one) — a running turn's answer isn't final yet.
export function verifyTurnOf(container, root, rule, { running = null } = {}) {
  if (!container || !root || !container.contains(root)) return null;
  const opening = openingOf(container, root);
  if (!opening) return null;
  const turnId = opening.anchor.dataset.turnId || null;
  if (!turnId) return null;
  if (running && (opening.last || (running.turnId && running.turnId === turnId))) return null;
  const final = finalAnswer(container, opening.anchor, rule);
  return final && (final === root || final.contains(root)) ? turnId : null;
}
