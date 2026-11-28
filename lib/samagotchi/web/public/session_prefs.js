// A session's own view settings (per browser, localStorage through
// storage.js): the stage's fold, the composer's dragged height and its fold,
// the working-set rail's fold, the working-set list's folded sections
// (ws_sections.js WS_SECTION_FOLD, defined there: a new export here would
// blank a page holding this module cached), and the composer's draft text
// (drafts.js, draft_keys.js COMPOSER_DRAFT, the same way). Each is kept under `<key>:<session>`, so what
// you do to one session's window never shows in another, and a session never
// set by hand follows the default: the page's own (the stage fold's comes
// from config, web.stage_collapsed, as <body data-stage-collapsed="1">), else
// the module's built-in one (+fallback+).
//
// With no session (the start page) nothing is written: the value lives in
// this page's memory only, until a reload.
//
// The old global keys (chi_stage_collapsed, chi_composer_floor,
// chi_composer_collapsed, chi_working_set_collapsed) are neither read nor
// written, and left in storage as they are.
//
// One sweep for all of its keys (sweepSessionPrefs), with an unscoped session
// list only: these keys record no project root, so a project's list, which
// knows its own sessions only, sweeps nothing.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { readStored, removeStored, storedKeys, writeStored } from "./storage.js";
import { WS_SECTION_FOLD } from "./ws_sections.js";
import { COMPOSER_DRAFT } from "./draft_keys.js";

export const STAGE_FOLD = "chi_stage_collapsed";
export const COMPOSER_FLOOR = "chi_composer_floor";
export const COMPOSER_FOLD = "chi_composer_collapsed";
export const WS_RAIL_FOLD = "chi_working_set_collapsed";
// And the composer's draft text (drafts.js; its key is draft_keys.js'): swept with them.
export const PREF_KEYS = [STAGE_FOLD, COMPOSER_FLOOR, COMPOSER_FOLD, WS_RAIL_FOLD, WS_SECTION_FOLD, COMPOSER_DRAFT];

// The page's defaults: <body>'s data attribute that turns a key on ("1").
const PAGE_DEFAULTS = { [STAGE_FOLD]: "stageCollapsed" };

// The start page's values (no session), in memory only.
const unsaved = new Map();

// The stored key for +key+ in +session+, null without one.
export function prefKey(key, session) {
  return session ? `${key}:${session}` : null;
}

// The page's default for +key+ ("1" when its body attribute is on), else null.
function pageDefault(key) {
  const attr = PAGE_DEFAULTS[key];
  if (!attr) return null;
  try {
    return globalThis.document?.body?.dataset?.[attr] === "1" ? "1" : null;
  } catch (_) {
    return null;
  }
}

// +session+'s value for +key+ (a string), else the page's default, else +fallback+.
export function read(key, session, fallback = null) {
  const own = session ? readStored(prefKey(key, session)) : (unsaved.has(key) ? unsaved.get(key) : null);
  if (own !== null) return own;
  return pageDefault(key) ?? fallback;
}

// +value+ (a string) for +key+ in +session+ only; no session: in memory.
export function write(key, session, value) {
  if (!session) {
    unsaved.set(key, String(value));
    return;
  }
  writeStored(prefKey(key, session), String(value));
}

// +session+'s own value for +key+ forgotten (it follows the default again);
// no session: the memory's.
export function forget(key, session) {
  if (!session) {
    unsaved.delete(key);
    return;
  }
  removeStored(prefKey(key, session));
}

// The session list loaded (+sessions+, each {id}): the keys of sessions not
// in it go. +scoped+ (a project's list): nothing goes. An empty list sweeps
// nothing either: chi web's hub answers one before its first scan (a page
// reloaded as chi web restarts), and the drafts' text would go with it.
export function sweepSessionPrefs(sessions, { scoped = false } = {}) {
  if (scoped) return;
  const ids = new Set((Array.isArray(sessions) ? sessions : []).map((s) => s?.id).filter(Boolean));
  if (!ids.size) return;
  for (const key of PREF_KEYS) {
    const prefix = `${key}:`;
    for (const stored of storedKeys(prefix)) {
      if (!ids.has(stored.slice(prefix.length))) removeStored(stored);
    }
  }
}
