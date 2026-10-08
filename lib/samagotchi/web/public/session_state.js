// What the page knows about the open session: the info bar's fields, the
// composer's owner check, the command list's commands and the turn timing.
// One object, so switching sessions starts every field from here (a field
// the previous session set, its "delegated by" parent, its commands, never
// shows for the next one).

import { normalizeTiming } from "./timing.js";

export function emptySessionState() {
  return {
    firstPreview: "",
    usedMemories: [],
    // The session's --memory and --mute lists (from the session card; shown
    // in the info bar's tooltip).
    preloadedMemories: [],
    mutedMemories: [],
    // The model notes the session's prompt carried (its prompt_notes: name,
    // scope, chars, digest; the info bar's notes chip).
    promptNotes: [],
    // A delegated session's parent (the info bar's "delegated by" chip).
    parentId: null,
    ctxPct: null,
    // Window the kernel resolved for the running generation (:generation_started).
    ctxWindow: null,
    // Where it came from ("server", "config", … "default": chi's guess).
    ctxWindowSource: null,
    status: "",
    model: "",
    // What the worker's server said it served for a model name: [served, asked].
    served: null,
    dir: "",
    // Who holds the session: "worker" (shared), "tui" (a plain terminal chi;
    // sending would be refused) or null.
    owner: null,
    // The session's commands (its worker's, plugins' too) for the / list.
    commands: [],
    // The chi its live worker runs and what it can do (the session card's
    // worker_version / worker_features): the info bar's stale-worker badge.
    workerVersion: null,
    workerFeatures: [],
    // The LLM context strategy, apply rule and budget the next turn runs
    // under, each with its source (the info bar's llm ctx chip), or null.
    llmContext: null,
    timing: normalizeTiming(),
  };
}
