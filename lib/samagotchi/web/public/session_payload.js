// A partial re-read of the open session (GET /sessions/:id with ?tail,
// ?recent…): the fields of the page's session state it brings, read as a
// full load reads them (session_state.js sessionStateFrom), so a field's
// rule lives in one place. app.js applySessionPayload assigns them into
// `current`; the caller then calls the field's redraw
// (docs/internals/web-frontend.md, "Writes and their redraws").
//
// A new module, not an export of session_state.js: the page's modules are
// cached at unversioned URLs, and a new export of an old module would
// leave a cached copy without it.

import { sessionStateFrom } from "./session_state.js";

// Where each field comes from in the payload: a field whose source the
// payload doesn't carry (a partial read leaves it out, or an older chi web
// never sent it) is not touched. Fields not listed are always taken.
const SOURCES = {
  status: (d) => d.session?.status || undefined,
  model: (d) => d.session?.model_name,
  dir: (d) => d.session?.working_directory,
  usedMemories: (d) => (Array.isArray(d.session?.used_memory_names) ? d.session.used_memory_names : undefined),
  preloadedMemories: (d) => (Array.isArray(d.session?.preloaded_memory_names) ? d.session.preloaded_memory_names : undefined),
  mutedMemories: (d) => (Array.isArray(d.session?.muted_memory_names) ? d.session.muted_memory_names : undefined),
  promptNotes: (d) => (Array.isArray(d.session?.prompt_notes) ? d.session.prompt_notes : undefined),
  verdicts: (d) => (Array.isArray(d.session?.verdicts) ? d.session.verdicts : undefined),
  verifyFresh: (d) => (Array.isArray(d.session?.verify_fresh) ? d.session.verify_fresh : undefined),
  commands: (d) => (Array.isArray(d.commands) ? d.commands : undefined),
  timing: (d) => d.timing,
};

// The named +fields+ of the session state +data+ sets (sessionStateFrom's
// values), those whose source it carries.
// @param data a GET /sessions/:id answer (it has a session)
// @param fields the state's keys (emptySessionState's), e.g. ["status"]
// @return {field: value} for the fields it brings
export function sessionFieldsFrom(data, fields) {
  if (!data?.session) return {};
  const all = sessionStateFrom(data);
  const out = {};
  for (const field of fields) {
    const source = SOURCES[field];
    if (source && source(data) === undefined) continue;
    if (field in all) out[field] = all[field];
  }
  return out;
}
