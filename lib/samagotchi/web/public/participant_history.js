// A participant's ↑/↓ list: their own accepted messages in this session,
// oldest first, as their conversation shows them (redacted), from
// GET /api/sessions/<id>/prompt_history (Web::ParticipantHistory; the
// viewer's own_prompt_history). Never the owner's /api/history. A module of
// its own for the mixed-cache rule (docs/internals/web-frontend.md).
import { api } from "./data.js";

export function fetchOwnHistory(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/prompt_history`, opts)
    .then((j) => (Array.isArray(j.entries) ? j.entries : []));
}

// The composer's loadHistory for +viewer+: the owner's shared history, a
// participant's own for the selected session, or null (no ↑ list).
export function historyLoader(viewer, { fetchHistory, selected }) {
  if (viewer.can("prompt_history")) return fetchHistory;
  if (!viewer.can("own_prompt_history")) return null;
  return () => {
    const id = selected();
    return id ? fetchOwnHistory(id) : Promise.resolve([]);
  };
}

// Whether the delivery line's idle hint names ↑ history.
export function hasHistory(viewer) {
  return viewer.can("prompt_history") || viewer.can("own_prompt_history");
}
