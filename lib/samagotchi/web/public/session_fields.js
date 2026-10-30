// The open session's fields (session_state.js emptySessionState), one entry
// each: where a payload (GET /sessions/:id) and a hub card carry it, what
// redraws it (session_store.js ORDER names) and who writes it. The table a
// new field or a new writer starts from (docs/internals/web-frontend.md,
// "The session store").
//
// Every write goes through the store (app.js `store`: update, setStatus,
// replaceCurrent), never `current.X = …` (the lint rule in
// eslint.config.js). Two writers stay outside, on purpose (D8):
// - live_timing.js sets `timing().activeTurn` in place (start, finish,
//   finishLine): the running turn's own clock, which mergeTurnTiming keeps.
// - verdict_fresh.js `startFresh` pushes onto `fresh.running`, which is
//   `verifyFresh` (verifyFreshState hands the array out): returning the
//   entry for an update would leave the card holding the old array.
//
// A new module: the page's modules are cached at unversioned URLs, and a
// new export of an old module would leave a cached copy without it.

import { withLiveStatus } from "./format.js";

const isList = (v) => Array.isArray(v);
const list = (v) => (isList(v) ? v : undefined);

// Per field:
//   source(payload)  the payload carries it (not undefined): a partial
//                    re-read takes it (session_payload.js sessionFieldsFrom).
//                    No source: a payload always sets it (sessionStateFrom),
//                    or never does (the page's own fields).
//   card(sess)       its value on a hub card (followSelectedSession)
//   redraws          what reads it (session_store.js ORDER)
//   writers          who writes it (besides renderSessionView's payload and
//                    forgetSession's reset, which write every field)
export const FIELDS = {
  firstPreview: { redraws: ["infoBar"], writers: "send_turn.js (the first prompt)" },
  usedMemories: {
    source: (d) => list(d.session?.used_memory_names),
    redraws: ["infoBar"],
    writers: "setUsedMemories (stream), readTurnEnd; both replace the card too",
  },
  preloadedMemories: { source: (d) => list(d.session?.preloaded_memory_names), redraws: ["infoBar"], writers: "the payload" },
  mutedMemories: { source: (d) => list(d.session?.muted_memory_names), redraws: ["infoBar"], writers: "the payload" },
  promptNotes: { source: (d) => list(d.session?.prompt_notes), redraws: ["infoBar"], writers: "readTurnEnd" },
  parentId: { redraws: ["infoBar"], writers: "the payload" },
  continues: { redraws: ["infoBar"], writers: "the payload" },
  review: { redraws: ["infoBar"], writers: "the payload" },
  verdicts: {
    source: (d) => list(d.session?.verdicts),
    redraws: [],
    writers: "placeVerdict (its card draws itself: placeVerdictWithFresh)",
  },
  verifyFresh: {
    source: (d) => list(d.session?.verify_fresh),
    redraws: [],
    writers: "placeVerdict (settleRunning); verdict_fresh.js startFresh pushes in place (D8)",
  },
  createdAt: { redraws: ["infoBar"], writers: "the payload" },
  ctxPct: { redraws: ["infoBar"], writers: "stream_handlers.js (generation_chunk, context_status)" },
  ctxWindow: { redraws: ["infoBar"], writers: "stream_handlers.js (generation_started, context_status)" },
  ctxWindowSource: { redraws: ["infoBar"], writers: "stream_handlers.js (generation_started, context_status)" },
  ctxUnknownAfterSwitch: { redraws: ["infoBar"], writers: "stream_handlers.js (generation_started, context_status)" },
  status: {
    source: (d) => d.session?.status || undefined,
    card: (sess) => sess.status,
    redraws: ["infoBar"],
    writers: "store.setStatus only (statusWrite below): the hub, the stream, a turn end's re-read, Stop, the payload",
  },
  thinking: { redraws: ["settingsPanel", "infoBar"], writers: "stream_handlers.js command_ran" },
  model: {
    source: (d) => d.session?.model_name,
    redraws: ["infoBar"],
    writers: "stream_handlers.js command_ran (a new model also syncModelPick: an event, D9)",
  },
  served: { redraws: ["infoBar"], writers: "stream_handlers.js (command_ran, generation_completed)" },
  dir: { source: (d) => d.session?.working_directory, redraws: ["infoBar"], writers: "the payload" },
  owner: {
    card: (sess) => sess.owner || null,
    redraws: ["composer", "infoBar"],
    writers: "followSelectedSession, workerGone (worker → null), send_turn.js and composerCommands.ownedByTui (\"tui\")",
  },
  commands: {
    source: (d) => list(d.commands),
    redraws: ["infoBar"],
    writers: "the payload (the / list and the annotate bar read it at use; the bar refreshes the annotate bar)",
  },
  workerVersion: { card: (sess) => sess.worker_version || null, redraws: ["infoBar"], writers: "followSelectedSession" },
  workerFeatures: {
    card: (sess) => (isList(sess.worker_features) ? sess.worker_features : []),
    redraws: ["featureGates", "infoBar"],
    writers: "followSelectedSession",
  },
  bridgeUp: {
    card: (sess) => sess.bridge_up === true,
    redraws: ["featureGates", "infoBar"],
    writers: "followSelectedSession, workerGone",
  },
  llmContext: {
    redraws: ["settingsPanel", "workingSetStrategy", "infoBar"],
    writers: "stream_handlers.js command_ran",
  },
  reasoningHistory: { redraws: ["settingsPanel", "infoBar"], writers: "stream_handlers.js command_ran" },
  toolkit: { redraws: ["infoBar"], writers: "stream_handlers.js (command_ran, hook_notice)" },
  toolkitDefault: { redraws: ["infoBar"], writers: "the payload" },
  timing: {
    source: (d) => d.timing,
    redraws: ["infoBar"],
    writers: "mergeTurnTiming; stream_handlers.js (generation_completed: tokens, modelSegments; side_usage: side), " +
      "always a new object; live_timing.js sets activeTurn in place (D8)",
  },
  turnStarted: { redraws: ["composer", "infoBar"], writers: "setTurnRunning" },
  streamSeq: { redraws: [], writers: "resync" },
  streamFromGuess: { redraws: [], writers: "followWokenWorker, startStream, the stream's takeGuess" },
};

// The fields a hub card brings for the open session (followSelectedSession):
// its owner and worker. Never its status: that goes through setStatus, so
// "the hub's status only while not streaming" can't be bypassed.
const CARD_FIELDS = ["owner", "workerVersion", "workerFeatures", "bridgeUp"];

// @param sess a hub card (the open session's)
// @return {owner, workerVersion, workerFeatures, bridgeUp}
export function fieldsFromCard(sess) {
  return Object.fromEntries(CARD_FIELDS.map((key) => [key, FIELDS[key].card(sess)]));
}

// Whether a status write from +source+ applies, and what it does to the
// open session's card (null: the card is left alone).
//   payload  renderSessionView: always
//   hub      followSelectedSession: only while the stream isn't live
//   stream   setLiveStatus (turn_*, workerGone's idle): always; the card
//            takes it too (withLiveStatus: status, owner, updated_at)
//   turnEnd  readTurnEnd, the turn_canceled re-read: only while no turn
//            runs (a re-read landing after the next queued turn's
//            turn_started doesn't write its stored "idle" over "running";
//            mergeTurnTiming keeps activeTurn by the same test); the caller
//            skips a payload without one; readTurnEnd writes its card
//            itself, after its timing merge
//   stop     session_actions.js stoppedWorker: always; workerGone's
//            withoutWorker takes care of the card
// @param source one of the above
// @param streaming whether the open session's stream is live
// @param running whether a turn runs on the page (liveTurn.running)
// @return {apply, card: (sess, status) => sess | null}
export function statusWrite(source, { streaming = false, running = false } = {}) {
  switch (source) {
    case "payload": return { apply: true, card: null };
    case "hub": return { apply: !streaming, card: null };
    case "stream": return { apply: true, card: withLiveStatus };
    case "turnEnd": return { apply: !running, card: null };
    case "stop": return { apply: true, card: null };
    default: throw new Error(`statusWrite: no source ${source}`);
  }
}
