// The open session's participants by author ("p:<id>" → name), for the
// author badges on their prompts (turn_events.js promptOps, a reload's
// turn_block.js): the participants panel sets it when it reads the list. A
// prompt's own author_name (a saved message, turn_started) comes first; a
// badge drawn before the list came, with neither, says UNNAMED until
// nameUnnamedBadges names it.
import { authorColor, isParticipantAuthor, participantAuthor } from "./participant_model.js";
import { viewerSelf } from "./viewer_self.js";

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
// +mode+: the turn's participant_mode stamp ("review", "pair"; the
// message's, or turn_started's), kept as mode: when known.
export function authorBadge(author, name = null, mode = null) {
  if (!isParticipantAuthor(author)) return null;
  const known = name || participantName(author);
  return { author, name: known || UNNAMED, color: authorColor(author), ...(known ? {} : { unnamed: true }), ...(mode ? { mode } : {}) };
}

// A badge's text and tooltip (turn_html.js userBubbleTemplate), by the
// turn's mode: a participant's turn acts with the session's tools (pair,
// and a live prompt whose mode isn't known yet: a queued one, until
// setBadgeMode); a saved turn stamped "review", or saved with no stamp (an
// older chi's, as Steer reads it), could only read: the history render
// passes READ_ONLY for an unstamped one (turn_block.js).
export const PAIR = "pair";
export const READ_ONLY = "review";
// A participant looking (viewer_self.js) reads their turn by its name alone.
export const authorBadgeText = (name, mode = null) => {
  if (mode === READ_ONLY) return `${name} · read-only`;
  return viewerSelf() ? name : `${name} · pair`;
};
export const authorBadgeTitle = (name, mode = null) => (mode === READ_ONLY
  ? `A turn from ${name}, a participant, under an older chi: it could only read`
  : `A turn from ${name}, a participant: it acted with this session's tools, its asks came to you`);

// The badge on +bubble+ (a prompt drawn before its turn started) takes the
// turn's +mode+ once turn_started names it.
export function setBadgeMode(bubble, mode) {
  const badge = bubble?.querySelector?.(".author-badge");
  if (!badge || !mode) return;
  bubble.dataset.participantMode = mode;
  if (badge.dataset.unnamed) return;
  const name = participantName(bubble.dataset.author) || badge.textContent.replace(/ · (read-only|pair)$/, "");
  badge.textContent = authorBadgeText(name, mode);
  badge.title = authorBadgeTitle(name, mode);
}

// The badges under +root+ drawn before the list named their participant
// (data-unnamed) take the name now known. Bubbles are drawn once
// (turn_html.js elementOf), so their text is written by hand.
// @return how many were named
export function nameUnnamedBadges(root) {
  let named = 0;
  for (const badge of root?.querySelectorAll?.(".author-badge[data-unnamed]") || []) {
    const bubble = badge.closest("[data-author]");
    const name = participantName(bubble?.dataset.author);
    if (!name) continue;
    badge.textContent = authorBadgeText(name, bubble?.dataset.participantMode);
    badge.title = authorBadgeTitle(name, bubble?.dataset.participantMode);
    badge.removeAttribute("data-unnamed");
    named += 1;
  }
  return named;
}
