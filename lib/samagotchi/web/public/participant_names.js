// The open session's participants by author ("p:<id>" → name), for the
// author badges on their prompts (turn_events.js promptOps, a reload's
// turn_view.js): the participants panel sets it when it reads the list. A
// prompt's own author_name (a saved message, turn_started) comes first; a
// badge drawn before the list came, with neither, says UNNAMED until
// nameUnnamedBadges names it.
import { authorColor, participantAuthor } from "./participant_model.js";

export const UNNAMED = "a participant";

let names = new Map();

// @return whether the names changed (the panel then names the badges drawn
// without them)
export function setParticipantNames(grants) {
  const next = new Map((grants || []).filter((g) => g?.id).map((g) => [participantAuthor(g.id), String(g.name || "")]));
  const changed = next.size !== names.size || [...next].some(([author, name]) => names.get(author) !== name);
  names = next;
  return changed;
}

export function participantName(author) {
  return names.get(String(author || "")) || null;
}

// A participant's badge: {author, name, color}, and unnamed: true when
// neither the prompt nor the list named them yet; null for the owner's.
export function authorBadge(author, name = null) {
  if (!author || author === "owner") return null;
  const known = name || participantName(author);
  return { author, name: known || UNNAMED, color: authorColor(author), ...(known ? {} : { unnamed: true }) };
}

// A badge's text and tooltip (turn_html.js userBubbleTemplate).
export const authorBadgeText = (name) => `${name} · review`;
export const authorBadgeTitle = (name) => `A review comment from ${name}, a participant: its turn could only read`;

// The badges under +root+ drawn before the list named their participant
// (data-unnamed) take the name now known. Bubbles are drawn once
// (turn_html.js elementOf), so their text is written by hand.
// @return how many were named
export function nameUnnamedBadges(root) {
  let named = 0;
  for (const badge of root?.querySelectorAll?.(".author-badge[data-unnamed]") || []) {
    const name = participantName(badge.closest("[data-author]")?.dataset.author);
    if (!name) continue;
    badge.textContent = authorBadgeText(name);
    badge.title = authorBadgeTitle(name);
    badge.removeAttribute("data-unnamed");
    named += 1;
  }
  return named;
}
