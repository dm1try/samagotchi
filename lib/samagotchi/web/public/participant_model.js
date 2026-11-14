// A participant's author and colour, pure: the one place the web spells a
// participant's author ("p:<grant id>"), shared by the badges on their
// prompts (participant_names.js), the owner's participants panel, the
// question cards, notifications and the viewer's own identity
// (viewer_self.js).

// A participant's author: "p:" and its grant id, as the server writes it
// (Steer.author_for / PARTICIPANT_PREFIX): the one place the web spells it.
export const PARTICIPANT_PREFIX = "p:";
export const participantAuthor = (id) => `${PARTICIPANT_PREFIX}${id}`;
export const isParticipantAuthor = (by) => typeof by === "string" && by.startsWith(PARTICIPANT_PREFIX);

// Six author colours (tokens.css --author-1..6), one per participant id,
// the same on every page that shows them (the owner's badges too).
export const AUTHOR_SLOTS = 6;
export function authorSlot(author) {
  const id = String(author || "");
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) >>> 0;
  return (hash % AUTHOR_SLOTS) + 1;
}

// The CSS colour of an author: a participant's slot, else the owner's.
export function authorColor(author) {
  return isParticipantAuthor(author) ? `var(--author-${authorSlot(author)})` : "var(--author-owner)";
}
