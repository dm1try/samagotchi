// What the page knows about the open session: the info bar's fields, the
// composer's owner check, the command list's commands and the turn timing.
// One object, so switching sessions starts every field from here (a field
// the previous session set, its "delegated by" parent, its commands, never
// shows for the next one).

import { savedCtxPct } from "./ctx.js";
import { firstPreview, previewForCard } from "./format.js";
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
    // The previous link of its chain (its `continues`), or null.
    continues: null,
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

// The fields a session's payload (GET /sessions/:id) sets, read from it
// alone. ctxPct is left out when the payload has no saved fill, ctxWindow
// and ctxWindowSource when it has no window: the page keeps what it had
// (a running turn's replay streams over it).
export function sessionStateFrom(data) {
  const s = data.session;
  const state = {
    status: s.status,
    model: s.model_name,
    served: s.served_model ? [s.served_model, s.served_model_for, s.served_expected_by || null] : null,
    dir: s.working_directory,
    owner: s.owner || null,
    timing: normalizeTiming(data.timing),
  };
  // The saved fill, so a reloaded or stopped session shows it before its
  // next turn.
  const savedPct = savedCtxPct(data.timing?.context, s.llm_context?.budget_tokens);
  if (savedPct !== null) state.ctxPct = savedPct;
  if (data.timing?.context?.window_tokens) {
    state.ctxWindow = data.timing.context.window_tokens;
    state.ctxWindowSource = data.timing.context.window_source || null;
  }
  state.firstPreview = sessionFirstPreview(data);
  state.usedMemories = s.used_memory_names || [];
  state.preloadedMemories = s.preloaded_memory_names || [];
  state.mutedMemories = s.muted_memory_names || [];
  state.promptNotes = Array.isArray(s.prompt_notes) ? s.prompt_notes : [];
  state.llmContext = s.llm_context || null;
  state.thinking = s.thinking || null;
  state.parentId = s.parent_id || null;
  state.continues = s.continues || null;
  state.commands = Array.isArray(data.commands) ? data.commands : [];
  return state;
}

// The info bar's title: the first user message when the payload has
// messages, else the card's preview, else the first prompt of its history.
function sessionFirstPreview(data) {
  const s = data.session;
  let preview = s.first_preview || previewForCard(s);
  if (data.messages && data.messages.length) {
    const first = data.messages.find((m) => m.role === "user");
    if (first && first.content) preview = firstPreview(first.content);
  } else if (!preview && data.history && data.history.length) {
    const txt = firstPreview(data.history[0]);
    if (txt) preview = txt;
  }
  return preview;
}
