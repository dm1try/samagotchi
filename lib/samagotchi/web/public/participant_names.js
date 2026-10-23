// The open session's participants by author ("p:<id>" → name), for the
// author badges on their prompts (turn_events.js promptOps, a reload's
// turn_view.js): the participants panel sets it when it reads the list. A
// prompt's own author_name (a saved message, turn_started) comes first.
import { authorColor } from "./participant_model.js";

let names = new Map();

export function setParticipantNames(grants) {
  names = new Map((grants || []).filter((g) => g?.id).map((g) => [`p:${g.id}`, String(g.name || "")]));
}

export function participantName(author) {
  return names.get(String(author || "")) || null;
}

// A participant's badge: {author, name, color}; null for the owner's.
export function authorBadge(author, name = null) {
  if (!author || author === "owner") return null;
  return { author, name: name || participantName(author) || "a participant", color: authorColor(author) };
}
