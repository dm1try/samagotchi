// A partial re-read of the open session (GET /sessions/:id with ?tail,
// ?recent…): the fields of the page's session state it brings, read as a
// full load reads them (session_state.js sessionStateFrom), so a field's
// rule lives in one place. app.js applySessionPayload writes them through
// the store; the caller then calls the field's redraw
// (docs/internals/web-frontend.md, "The session store").
//
// A new module, not an export of session_state.js: the page's modules are
// cached at unversioned URLs, and a new export of an old module would
// leave a cached copy without it.

import { sessionStateFrom } from "./session_state.js";
import { FIELDS } from "./session_fields.js";

// Where each field comes from in the payload (session_fields.js FIELDS
// sources): a field whose source the payload doesn't carry (a partial read
// leaves it out, or an older chi web never sent it) is not touched. Fields
// without one are always taken.
//
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
    const source = FIELDS[field]?.source;
    if (source && source(data) === undefined) continue;
    if (field in all) out[field] = all[field];
  }
  return out;
}
