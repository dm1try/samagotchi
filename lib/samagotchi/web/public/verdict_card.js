import { findClaim, ownerClaimHash } from "./claim_link.js";

const TYPES = Object.freeze({
  confirmed: { icon: "✅", label: "confirmed" },
  refuted: { icon: "❌", label: "refuted" },
  unclear: { icon: "❓", label: "unclear" },
});

export const CHECK_NOT_ON_PAGE = "That check is no longer on this page.";

export function ownerCheckHash(sessions, currentSessionId, checkTurnId) {
  if (!Array.isArray(sessions) || typeof checkTurnId !== "string") return null;
  const session = sessions.find((candidate) =>
    candidate?.id !== currentSessionId
    && Array.isArray(candidate.verdicts)
    && candidate.verdicts.some((verdict) => verdict?.check_turn_id === checkTurnId));
  return session ? ownerClaimHash(session.id, { turnId: checkTurnId }) : null;
}

// A verdict's card on its source turn: after the bubble that holds the
// quote (+roots+, the page's claim roots selector; +opts+, how it reads the
// page's text, claim_link.js), the answer's first; a quote not found (a
// bubble not drawn yet): at the turn's end. Cards on one bubble keep their
// order; a card already on the page is returned as it is.
export function placeVerdict(root, record, {
  who = "Owner", author = null, onMissingCheck = null, roots = null, opts = {},
} = {}) {
  const anchor = record?.anchor;
  const type = TYPES[record?.verdict];
  if (!root || !type || typeof anchor?.turn_id !== "string" || typeof anchor?.quote !== "string"
      || typeof record.reason !== "string" || typeof record.check_turn_id !== "string") return null;

  const elements = [...root.querySelectorAll("[data-turn-id]")];
  const source = elements.find((element) => element.dataset.turnId === anchor.turn_id);
  if (!source) return null;
  const cards = [...root.querySelectorAll(".verify-verdict")];
  const existing = cards.find((card) => card.dataset.checkTurnId === record.check_turn_id);
  if (existing) return existing;

  const doc = root.ownerDocument;
  const card = doc.createElement("aside");
  card.className = `verify-verdict ${record.verdict}`;
  card.dataset.sourceTurnId = anchor.turn_id;
  card.dataset.checkTurnId = record.check_turn_id;
  if (author) card.dataset.author = author;
  card.setAttribute("aria-label", `Claim verdict: ${type.label}`);

  const heading = doc.createElement("div");
  heading.className = "verify-verdict-heading";
  heading.append(doc.createTextNode(`${type.icon} ${type.label} · `));
  const name = doc.createElement("span");
  name.className = "verify-verdict-who";
  name.textContent = who;
  heading.append(name);

  const quote = doc.createElement("blockquote");
  quote.className = "verify-verdict-quote";
  quote.textContent = anchor.quote;
  const reason = doc.createElement("p");
  reason.className = "verify-verdict-reason";
  reason.textContent = record.reason;

  // Verify fresh (an unclear verdict's button, its fresh verdicts): verdict_fresh.js.
  const link = doc.createElement("a");
  link.href = "#";
  link.className = "verify-verdict-link";
  link.textContent = "View check";
  link.addEventListener("click", (event) => {
    event.preventDefault();
    const check = [...root.querySelectorAll("[data-turn-id]")]
      .find((element) => element.dataset.turnId === record.check_turn_id);
    if (check) check.scrollIntoView?.({ behavior: "smooth", block: "center" });
    else onMissingCheck?.(record);
  });
  card.append(heading, quote, reason, link);

  afterCards(quotedElement(source, anchor.quote, roots, opts) || turnEnd(source)).after(card);
  return card;
}

// The element at +source+'s level that holds the quote: of the turn's
// roots after its prompt, the last match first (the answer the Engine
// checked the quote against comes after the turn's steps).
function quotedElement(source, quote, selector, opts) {
  if (!selector || !source.parentElement) return null;
  const level = source.parentElement;
  const candidates = turnElements(source).flatMap((element) =>
    [...(element.matches(selector) ? [element] : []), ...element.querySelectorAll(selector)]).reverse();
  const hit = findClaim(candidates.map((candidate) => candidate.textContent), { q: quote }, opts);
  if (!hit) return null;
  let element = candidates[hit.at];
  while (element && element.parentElement !== level) element = element.parentElement;
  return element || null;
}

// +source+'s turn: its siblings after it up to the next turn's opening
// (or a gap divider before it).
function turnElements(source) {
  const elements = [];
  for (let next = source.nextElementSibling; next; next = next.nextElementSibling) {
    if (next.matches("[data-turn-id]") || next.querySelector("[data-turn-id]")) break;
    elements.push(next);
  }
  while (elements.at(-1)?.classList.contains("time-gap")) elements.pop();
  return elements;
}

function turnEnd(source) {
  return turnElements(source).at(-1) || source;
}

// +element+, or the last of the verdict cards right after it.
function afterCards(element) {
  let last = element;
  while (last.nextElementSibling?.classList.contains("verify-verdict")) last = last.nextElementSibling;
  return last;
}

export function nameVerdictCards(root, nameFor) {
  for (const card of root?.querySelectorAll?.(".verify-verdict[data-author]") || []) {
    const name = nameFor(card.dataset.author);
    if (name) card.querySelector(".verify-verdict-who").textContent = name;
  }
}
