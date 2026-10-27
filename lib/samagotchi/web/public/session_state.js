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
    // A review session's {subjects, from} (its `review`), or null.
    review: null,
    verdicts: [],
    // The Verify fresh checks running ({of, child_id}; the summary's verify_fresh).
    verifyFresh: [],
    // Its start (the summary's created_at; the info bar's chain links are
    // times on its day), or null.
    createdAt: null,
    ctxPct: null,
    // Window the kernel resolved for the running generation (:generation_started).
    ctxWindow: null,
    // Where it came from ("server", "config", … "default": chi's guess).
    ctxWindowSource: null,
    // A /model's new window didn't resolve and no request has started since
    // (stream_handlers.js context_status): the ctx tooltip says it waits.
    ctxUnknownAfterSwitch: false,
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
    // Which of its reasoning the model gets back from the next turn on, with
    // its source (the reasoning history chip), or null (a native host).
    reasoningHistory: null,
    toolkit: null,
    timing: normalizeTiming(),
    // A turn started on it while the page had it open (setTurnRunning): a
    // fresh link's picker goes at once, before the timing re-read brings the
    // turn's record (chains.js freshLink). Never from a payload, so a resync
    // of the same session keeps it.
    turnStarted: false,
    // The event id (or, from an older worker, the event_seq) the session was
    // rendered at (null: no live worker then), where a stream opened later
    // has to start; set by the page's resync, not by the payload.
    streamSeq: null,
    // The stream was opened from 0 (a wake with no cursor to go on) and no
    // new turn has started on it yet (app.js followWokenWorker).
    streamFromGuess: false,
    // When the info bar's "copy chi --attach" copied (its "copied ✓").
    attachCopiedAt: 0,
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
    // Its live worker's chi and features (null and [] without one): a
    // switch shows its stale-worker badge, task stop and queue at once,
    // not at the session's next hub event (followSelectedSession).
    workerVersion: s.worker_version || null,
    workerFeatures: Array.isArray(s.worker_features) ? s.worker_features : [],
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
  // null on a native host (it ignores the level) and from an older worker.
  state.reasoningHistory = s.reasoning_history || null;
  // The tools chip's (null on full).
  state.toolkit = s.toolkit || null;
  state.parentId = s.parent_id || null;
  state.continues = s.continues || null;
  state.review = s.review || null;
  state.verdicts = Array.isArray(s.verdicts) ? s.verdicts : [];
  state.verifyFresh = Array.isArray(s.verify_fresh) ? s.verify_fresh : [];
  state.createdAt = s.created_at || null;
  state.commands = Array.isArray(data.commands) ? data.commands : [];
  return state;
}

// The info bar's title: the session's own title (/title), else its auto
// title, else its recap's first sentence (as its card), else the first user message when the payload has messages, else the card's preview, else
// the first prompt of its history.
function sessionFirstPreview(data) {
  const s = data.session;
  const named = s.title || s.auto_title || s.recap;
  if (named) return firstPreview(named);
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
