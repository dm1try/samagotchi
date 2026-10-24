// Pure helpers for the Bridge's turn events (no DOM), so app.js's handlers
// stay thin and the logic runs under `node --test`.

import { authorBadge } from "./participant_names.js";
import { ACTIVITY_FIELDS, EVENT_FIELDS, pickFields } from "./activity.js";

// Read turn_summary.output; Bridge::ClientEvent omits result for clients.
export function turnOutput(data) {
  if (!data) return "";
  const output = data.turn_summary?.output;
  return typeof output === "string" ? output.trim() : "";
}

// The end line for a turn whose worker went away mid-turn (the footer's
// stop, a crash): no turn_canceled comes, so the page ends the turn itself.
// The footer's stop is the user's, drawn as a cancel is (\u25A0, timing.js
// cancelLineText); a worker that exited on its own is a failure (\u2715).
// null when no turn was running.
export function workerGoneText({ turnRunning, stopped = false }) {
  if (!turnRunning) return null;
  return stopped ? "\u25A0 canceled (session stopped)" : "\u2715 canceled (worker exited)";
}

// Whether the turn view ends now, or waits for the session re-read: a stream
// that was open and dropped with no stop (a phone briefly offline) says
// nothing about the worker, and `resync` re-renders the turn and adds the end
// line only when no worker took it — ending the view first is a wrong flash.
// A stop, or a stream that never opened at all, is the worker leaving: end
// now, and the re-read repeats it only when nothing took the turn.
// @return {{endNow: Boolean, endText: String|null}}
export function streamDropEnd({ turnRunning, stopped = false, opened = true }) {
  const endText = workerGoneText({ turnRunning, stopped });
  return { endNow: Boolean(endText) && (stopped || !opened), endText };
}

// A session re-read that failed (the phone still offline, chi web restarting):
// try again, backing off (3 s, 6 s, 9 s), and stop after +max+ tries — the
// hub's next event for the session re-reads it then. Nothing else changes in
// the meantime: a turn a worker still owns keeps showing as running.
// @return {{attempt: number, delayMs: number|null}}  (null: stop trying)
export function resyncRetry({ attempts = 0, max = 3, baseMs = 3000 }) {
  const next = attempts + 1;
  return next <= max ? { attempt: next, delayMs: next * baseMs } : { attempt: attempts, delayMs: null };
}

// How long a turn's answer waits for the after_turn hooks' answer_display
// before the page stops waiting and pops what it has (4.14).
const DISPLAY_WAIT_MS = 20000;

// The wait between a turn_completed with display_pending and its
// answer_display. The worker can die in between (a crash, a stop, an idle
// exit) and never send one, so the wait also ends on the caller's finish()
// (workerGone, a re-render) and by the timeout: it must never hold the
// turn's answer bubble forever.
// @return {{promise, finish, settled: () => Boolean}}
export function displayWait({
  timeoutMs = DISPLAY_WAIT_MS, setTimeoutImpl = setTimeout, clearTimeoutImpl = clearTimeout,
} = {}) {
  let settle = null;
  let done = false;
  const promise = new Promise((resolve) => { settle = resolve; });
  const finish = () => {
    if (done) return;
    done = true;
    clearTimeoutImpl(timer);
    settle();
  };
  const timer = setTimeoutImpl(finish, timeoutMs);
  return { promise, finish, settled: () => done };
}

// This tab's id in the events (`origin.client_id`, turn_enqueued's
// client_id): kept in sessionStorage per tab, so a reload mid-turn still
// recognizes this tab's own prompt (4.03), which a fresh random id every
// load labelled "web". Falls back to a fresh id when sessionStorage is
// unavailable (a private window that refuses it) or holds nonsense.
export const CLIENT_ID_KEY = "chi_client_id";
export function newClientId(storage = safeSessionStorage()) {
  const kept = readClientId(storage);
  if (kept) return kept;
  const id = `web:${Math.random().toString(36).slice(2, 10).padEnd(8, "0")}`;
  writeClientId(storage, id);
  return id;
}

function safeSessionStorage() {
  try {
    return globalThis.sessionStorage || null;
  } catch (_) {
    return null;
  }
}

function readClientId(storage) {
  try {
    const value = storage?.getItem(CLIENT_ID_KEY);
    return typeof value === "string" && /^web:/.test(value) ? value : null;
  } catch (_) {
    return null;
  }
}

function writeClientId(storage, id) {
  try {
    storage?.setItem(CLIENT_ID_KEY, id);
  } catch (_) {
    // Full or refused storage: the id stays for this page only.
  }
}

export function isOwn(clientId, myId) {
  return clientId != null && clientId === myId;
}

// As the TUI labels them (Formatting::CLIENT_LABELS); this file's label
// helpers and the TUI's agree per spec/shared/labels_matrix.json.
// By the whole id or its prefix (up to and with its first ":"); an id
// chi doesn't know is "automatic", not the user (ClientId.human?).
const CLIENT_LABELS = Object.freeze({
  "tui:": "tui", "web:": "web", "system:": "reminder", "delegate:": "delegate", "child:": "delegate report",
  "cli:send": "chi send", "cli:answer": "chi answer", plugin: "plugin", "review:": "review",
});
const AUTOMATIC_LABEL = "automatic";

// A delegate child's report comes in as client child:<id8> (ChildReports).
const REPORT_CLIENT = "child:";
export function isReportClient(clientId) {
  return String(clientId || "").startsWith(REPORT_CLIENT);
}

// A turn chi ran because an attached context source changed: context:<name>.
const CONTEXT_CLIENT = "context:";
// A turn chi ran because a background task the session started finished
// unseen: task:<task id> (the Worker's finish wake).
const TASK_CLIENT = "task:";

// A task id as people read it: the random part a task_create id ends with
// (it starts with the time), else its first 8 chars (TaskRecord.short_id).
function shortTaskId(id) {
  const m = /-([0-9a-f]{8})$/i.exec(id);
  return m ? m[1] : id.slice(0, 8);
}

// The label on another client's prompt, by its client_id prefix; a context
// change's turn as "context <name> changed", a finished task's as
// "task <id8> finished".
export function clientLabel(clientId) {
  if (!clientId) return null;
  const id = String(clientId);
  if (id.startsWith(CONTEXT_CLIENT) && id.length > CONTEXT_CLIENT.length) return `context ${id.slice(CONTEXT_CLIENT.length)} changed`;
  if (id.startsWith(TASK_CLIENT) && id.length > TASK_CLIENT.length) return `task ${shortTaskId(id.slice(TASK_CLIENT.length))} finished`;
  const colon = id.indexOf(":");
  return CLIENT_LABELS[id] || (colon >= 0 && CLIENT_LABELS[id.slice(0, colon + 1)]) || AUTOMATIC_LABEL;
}

// The note for reminders a turn got (a reminder turn has no prompt).
export function reminderText(event) {
  const names = (event?.reminders || []).map((r) => (r && typeof r === "object" ? r.name : r)).filter(Boolean);
  return names.length ? `reminder: ${names.join(", ")}` : "reminder";
}

// Who a hook's notice is from: the bundle's name for a bundle hook
// ("known_names.rb (bundle known-names)"), chi's own notice by its word
// (thinking), else "hook".
export function hookNoticeLabel(hook) {
  const name = String(hook || "");
  const m = /\(bundle (.+)\)$/.exec(name);
  if (m) return m[1];
  // chi's own notices name themselves with a bare word (thinking).
  return /^[a-z][a-z0-9-]*$/.test(name) ? name : "hook";
}

// The row a step gets when the loop asks again after an empty answer, or
// after a plugin cut the generation (stopped_by: the bundle), or after a
// corrupt native generation (malformed).
export function emptyRetryLine({ attempt, of, stopped_by: stoppedBy, malformed } = {}) {
  const what = stoppedBy ? `cut by ${stoppedBy}` : malformed ? "malformed answer" : "empty answer";
  return `↻ ${what}, asking again (${attempt}/${of})`;
}

// The row a step gets when a message for the running turn cut a generation
// that was only thinking (steer_cut; source "" is the user's, as is an
// unknown one). The TUI words it the same (spec/shared/labels_matrix.json).
const STEER_CUT_FOR = {
  chi_send: "a message sent with chi send",
  parent_agent: "the parent agent's message",
};
export function steerCutLine({ source } = {}) {
  return `↪ cut in for ${STEER_CUT_FOR[source] || "your message"}`;
}

// The ✂ row of a batch of LLM context edits the server applied
// (llm_context_edited, LLMContextNotice): its line as the server built
// it ("✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k tokens"),
// so the web and the TUI say the same.
export function llmContextLine({ text } = {}) {
  return text || "✂ LLM context edited";
}

// The ✂ row's hover: what each group did, one line per output (its id,
// tool and title), and what the batch costs ("~": chars/4).
export function llmContextHover({ groups = [], freed_tokens: freed, tail_tokens: tail, staged, moment } = {}) {
  const lines = [];
  const output = (item) => [item.id, item.tool, item.title].filter(Boolean).join(" ");
  for (const group of Array.isArray(groups) ? groups : []) {
    const items = Array.isArray(group.items) ? group.items : [];
    if (group.kind === "stale") {
      lines.push("Stubbed as stale:");
      for (const item of items) lines.push(`  ${output(item)}${item.note ? ` — ${item.note}` : ""}`);
    } else if (group.kind === "forget") {
      lines.push(`Forgotten by the ${group.by || "model"}: ${group.note || ""}`);
      for (const item of items) lines.push(`  ${output(item)}${item.kept ? ` · lines ${item.kept} kept` : ""}`);
    }
  }
  const cost = [];
  if (Number(freed) > 0) cost.push(`frees ~${freed} tokens`);
  if (Number(tail) > 0) cost.push(`the server reads ~${tail} tokens again`);
  if (cost.length) lines.push(cost.join("; "));
  if (Number(staged) > 0) lines.push(`${staged} more staged until the turn ends`);
  lines.push(moment === "turn_end" ? "Sent from the next turn on." : "Sent from the next request on.");
  lines.push("The session keeps the originals.");
  return lines.join("\n");
}

// A ✂ row's notice data (turnDom.notice, placeTurnNotice).
export function llmContextNotice(data) {
  return { line: llmContextLine(data), cls: "llm-context", title: llmContextHover(data) };
}

// The one muted line for a turn that ended with no answer (turn_completed's
// turn_summary.empty_answer, or a reloaded turn's marker), or one the
// provider refused (its `refusal`, with the category when named): the TUI
// words it the same (TurnNote.empty_answer_line; spec/shared/labels_matrix.json).
export function emptyAnswerLine({ retries = 0, refusal = null } = {}) {
  if (refusal) {
    const category = String(refusal.category ?? "").trim();
    return `no answer: refused by the provider${category ? ` (${category})` : ""}`;
  }
  const count = Number(retries) || 0;
  const after = count > 0 ? ` (after ${count} ${count === 1 ? "retry" : "retries"})` : "";
  return `no answer: the model returned nothing${after}`;
}

// The text of a turn's row from a snapshot entry (CardStore): a hook's
// notice as "<label>: text", the loop's asking-again row as its line.
export function noticeLine(entry = {}) {
  if (entry.type === "empty_answer_retry") return emptyRetryLine(entry);
  if (entry.type === "steer_cut") return steerCutLine(entry);
  if (entry.type === "llm_context_edited") return llmContextLine(entry);
  return `${hookNoticeLabel(entry.hook)}: ${entry.text || ""}`;
}

// The live turn's status while the provider is asked again after an error
// (generation_retrying): "↻ retrying (503) in 4.0s, 2/5" (retry 2 of 5).
// The TUI words it the same (Formatting#format_generation_retry_line;
// spec/shared/labels_matrix.json).
export function retryStatusLine({ attempt, max_retries, next_delay, status, error_class, restarted } = {}) {
  // restarted: a dropped stream's step asked again (the chat loop's).
  const why = restarted ? "stream dropped" : status || String(error_class || "").split("::").pop();
  // null/"" are no delay (Number would make them 0).
  const delay = next_delay === null || next_delay === "" ? NaN : Number(next_delay);
  // Rounded as Ruby's Float#round does (half away from zero), then one decimal.
  const when = Number.isFinite(delay) ? ` in ${(Math.round(delay * 10) / 10).toFixed(1)}s` : "";
  const count = attempt ? `, ${attempt}${max_retries ? `/${max_retries}` : ""}` : "";
  return `↻ retrying${why ? ` (${why})` : ""}${when}${count}`;
}

// The live turn's status while it waits for plugins' slow setup before its
// first request (plugin_init_wait).
export function initWaitLine({ tasks } = {}) {
  const labels = (tasks || []).map((t) => [t?.bundle, t?.label].filter(Boolean).join(": ")).filter(Boolean);
  return `waiting for ${labels.length ? labels.join(" · ") : "plugins"}…`;
}

// What an event does to the prompt bubbles, as a list of ops for app.js:
//   add   — a bubble for a prompt this tab hasn't shown (state queued /
//           started / steered, labelled by its sender)
//   tag   — this tab's own local echo gets its enqueued_id
//   start — the bubble's turn started (drops the "queued" badge)
//   steer — the bubble was merged into the running turn
//   remove — the queued message was taken back before it ran (turn_dequeued,
//           whoever removed it): its bubble goes
//   report — the merge brought a delegate child's report (origin
//           child:<id8>, no bubble anywhere): its text gets a labelled one
// `known(enqueuedId)` says whether a bubble carries that id already;
// `unmatchedMerge` whether the last input_merged had an origin with no
// bubble ("report": a delegate report's); `wakeStart` whether this is the
// first merge of a turn chi ran for reports (its bubble starts the turn,
// no "steered" badge, as a reload shows it).
// A participant's prompt's badge, as an op's field ({author}); {} for the
// owner's, so their ops stay as they were.
function authorOf(author, name = null) {
  const badge = authorBadge(author, name);
  return badge ? { author: badge } : {};
}

export function promptOps(event, { myId, known, unmatchedMerge = false, wakeStart = false }) {
  if (!event) return [];
  switch (event.type) {
    case "turn_enqueued": {
      const id = event.enqueued_id;
      // Queued for after the running turn (delivery queue): its bubble says so.
      const delivery = event.delivery ? { delivery: event.delivery } : {};
      if (isOwn(event.client_id, myId)) return [withImages({ op: "tag", enqueuedId: id, prompt: event.prompt, ...delivery }, event.images)];
      if (id && known(id)) return [];
      return [withImages({ op: "add", enqueuedId: id, prompt: event.prompt, state: "queued", label: clientLabel(event.client_id), ...delivery, ...authorOf(event.author) }, event.images)];
    }
    case "turn_started": {
      if (event.continue || !event.prompt) return [];
      const origin = event.origin || {};
      const id = origin.enqueued_id || null;
      if ((id && known(id)) || isOwn(origin.client_id, myId)) {
        // Images too: a resync can have wiped the own echo, and the page then
        // draws the bubble from this.
        return [withImages({ op: "start", enqueuedId: id, prompt: event.prompt }, event.images)];
      }
      return [withImages({ op: "add", enqueuedId: id, prompt: event.prompt, state: "started", label: clientLabel(origin.client_id), ...authorOf(event.author || origin.author, event.author_name) }, event.images)];
    }
    case "turn_dequeued":
      return event.enqueued_id ? [{ op: "remove", enqueuedId: event.enqueued_id }] : [];
    case "input_merged": {
      const ops = (event.origins || []).filter((o) => o && o.enqueued_id).map((o) =>
        known(o.enqueued_id) ? { op: "steer", enqueuedId: o.enqueued_id } : { op: "steer", enqueuedId: o.enqueued_id, unmatched: true },
      );
      if ((event.origins || []).some((o) => o && !o.enqueued_id && isReportClient(o.client_id))) ops.push({ op: "report" });
      return ops;
    }
    case "pending_input_merged":
      if (!unmatchedMerge || !event.content) return [];
      if (unmatchedMerge === "report") {
        return [{ op: "add", enqueuedId: null, prompt: event.content, state: wakeStart ? null : "steered", label: clientLabel(REPORT_CLIENT) }];
      }
      return [{ op: "add", enqueuedId: null, prompt: event.content, state: "steered", label: null }];
    default:
      return [];
  }
}

// A stream opened with no cursor (a worker woken after a render that had
// none) replays the worker's events from its start: a turn_started for a
// turn the page drew already (+turnRecords+, the render's timing) means
// that replay overlaps the render, and the page re-reads the session
// rather than drawing the turn twice (4.01).
export function replaysDrawnTurn(event, turnRecords = []) {
  if (event?.type !== "turn_started" || !event.turn_id) return false;
  return turnRecords.some((record) => record.id === event.turn_id);
}

// A session view from the server (GET /api/sessions/:id on a live worker)
// as the live events that would have drawn it: the turn in progress (its
// parts in order), then the prompts queued behind it. app.js feeds these to
// its stream handlers, so a join renders exactly like watching live.
// `merged_input` is the one synthetic type: a prompt merged into the turn.
// A `notice` part carries its event as it came (TurnNotice). The TUI replays
// a turn the same way (TurnAccumulator.replay_events); spec/shared/
// turn_snapshot.json pins both.
export function snapshotEvents({ current_turn: turn = null, queued = [], queued_commands: commands = [], started_at = undefined } = {}) {
  const events = [];
  if (turn) {
    // The run's cut wait (TurnAccumulator, as turn_started carried it): the
    // composer's delivery line reads it.
    const cutAfter = turn.cut_after != null ? { cut_after: turn.cut_after } : {};
    // A participant's turn names them (TurnAccumulator keeps author, author_name).
    const author = turn.author ? { author: turn.author, ...(turn.author_name ? { author_name: turn.author_name } : {}) } : {};
    // Its wall time (TurnAccumulator keeps turn_started's at): the gap divider before it.
    const at = typeof turn.at === "string" ? { at: turn.at } : {};
    events.push(withImages({ type: "turn_started", prompt: turn.prompt, origin: turn.origin, continue: !!turn.continue, started_at, ...at, ...cutAfter, ...author }, turn.images));
    let textIteration = null; // a text bubble is open for this iteration
    const closeText = () => {
      if (textIteration !== null) events.push({ type: "generation_completed" });
      textIteration = null;
    };
    for (const part of turn.parts || []) {
      switch (part.kind) {
        // A generation the model is on: a join during a hold (no chunk yet)
        // shows its live step.
        case "generation":
          closeText();
          events.push({ type: "generation_started", iteration: part.iteration ?? null });
          break;
        // The chunks carry the part's iteration, so the turn view groups a
        // join like the live stream (turn_model.js).
        case "thinking":
          events.push({ type: "generation_chunk", text: "", thinking: part.text, iteration: part.iteration ?? null });
          break;
        case "text":
          if (textIteration !== null && textIteration !== part.iteration) closeText();
          textIteration = part.iteration;
          events.push({ type: "generation_chunk", text: part.text, thinking: "", iteration: part.iteration ?? null });
          break;
        case "tool": {
          closeText();
          const call = { iteration: part.iteration, call_index: part.call_index, tool: part.tool };
          if (part.label) call.label = part.label;
          // Its row fields, each in its place (activity.js ACTIVITY_FIELDS,
          // EVENT_FIELDS), as the live events carry them.
          const title = pickFields(part, ACTIVITY_FIELDS);
          const fields = pickFields(part, EVENT_FIELDS);
          // A running call's time so far (TurnAccumulator elapsed_ms): a join
          // clocks it from its start (activity.js markStart).
          const elapsed = part.status === "running" && part.elapsed_ms != null ? { elapsed_ms: part.elapsed_ms } : {};
          events.push({ type: "tool_call_started", ...call, params: part.params, ...title, ...fields, ...elapsed });
          if (part.status !== "running") {
            // The activity as the live event had it; action and duration_ms
            // only in snapshots from a worker that keeps them (the TUI's
            // row; the web times rows from the turn's tool records).
            const action = part.action ? { action: part.action } : {};
            const completed = {
              type: "tool_call_completed", ...call, output: part.output, output_truncated: !!part.output_truncated,
              activity: { ...action, tool: part.tool, status: part.status, params: part.params, ...title },
            };
            // A grep that found nothing: its row stays muted "no match".
            if (part.no_match) completed.activity.no_match = true;
            if (part.duration_ms != null) completed.duration_ms = part.duration_ms;
            if (part.diff) completed.diff = part.diff;
            Object.assign(completed, fields);
            events.push(withImages(completed, part.images));
          }
          break;
        }
        case "input":
          closeText();
          events.push({ type: "merged_input", content: part.text, origins: part.origins || [] });
          break;
        case "reminder":
          closeText();
          events.push({ type: "reminder_injected", reminders: part.reminders || [] });
          break;
        // One of the turn's rows (a hook's notice, an empty-answer retry, a
        // question and its answer): the event itself, which the live
        // handler draws where it drew it live.
        case "notice":
          closeText();
          if (part.event?.type) events.push({ ...part.event });
          break;
        // A plugin's steer: a steer-only merge, as live.
        case "steer":
          closeText();
          events.push({ type: "pending_input_merged", count: 0, content: null, steers: [{ source: part.source, text: part.text }] });
          break;
        default:
          break;
      }
    }
  }
  for (const entry of queued || []) {
    const delivery = entry.delivery ? { delivery: entry.delivery } : {};
    const author = entry.author ? { author: entry.author } : {};
    events.push(withImages({ type: "turn_enqueued", enqueued_id: entry.enqueued_id, client_id: entry.client_id, prompt: entry.prompt, ...delivery, ...author }, entry.images));
  }
  // Commands waiting for the turn's end: their bubbles, as live.
  for (const entry of commands || []) {
    events.push({ type: "command_queued", command_id: entry.command_id, client_id: entry.client_id, line: entry.line, waits: "turn_end" });
  }
  return events;
}

// +object+ with `images` when there are any (the shapes stay as they were
// for a turn without).
export function withImages(object, images) {
  return images?.length ? { ...object, images } : object;
}
