// Pure helpers for the Bridge's turn events (no DOM), so app.js's handlers
// stay thin and the logic runs under `node --test`.

// The answer text of a :turn_completed event. `turn_summary.output` is the
// contract; `result` is the KernelLoop result, which reaches the wire as its
// string form (older servers, other clients' fixtures).
export function turnOutput(data) {
  if (!data) return "";
  const summary = data.turn_summary?.output;
  const result = typeof data.result === "string" ? data.result : data.result?.output;
  const out = [summary, result, data.content, data.output].find((v) => typeof v === "string" && v.trim());
  return out ? out.trim() : "";
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

// How long a turn's answer waits for the after_turn hooks' answer_display
// before the page stops waiting and pops what it has (4.14).
export const DISPLAY_WAIT_MS = 20000;

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
  "cli:send": "chi send", "cli:answer": "chi answer", plugin: "plugin",
});
const AUTOMATIC_LABEL = "automatic";

// A delegate child's report comes in as client child:<id8> (ChildReports).
const REPORT_CLIENT = "child:";
export function isReportClient(clientId) {
  return String(clientId || "").startsWith(REPORT_CLIENT);
}

// A turn chi ran because an attached context source changed: context:<name>.
const CONTEXT_CLIENT = "context:";

// The label on another client's prompt, by its client_id prefix; a context
// change's turn as "context <name> changed".
export function clientLabel(clientId) {
  if (!clientId) return null;
  const id = String(clientId);
  if (id.startsWith(CONTEXT_CLIENT) && id.length > CONTEXT_CLIENT.length) return `context ${id.slice(CONTEXT_CLIENT.length)} changed`;
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

// The one muted line for a turn that ended with no answer (turn_completed's
// turn_summary.empty_answer, or a reloaded turn's marker): the TUI words
// it the same (TurnNote.empty_answer_line; spec/shared/labels_matrix.json).
export function emptyAnswerLine({ retries = 0 } = {}) {
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
// (generation_retrying): "↻ retrying (503) in 4 s, 2/5" (retry 2 of 5).
export function retryStatusLine({ attempt, max_retries, next_delay, status, error_class } = {}) {
  const why = status || String(error_class || "").split("::").pop();
  const delay = Number(next_delay);
  const when = Number.isFinite(delay) ? ` in ${delay < 1 ? delay.toFixed(1) : Math.round(delay)} s` : "";
  const count = attempt ? `, ${attempt}${max_retries ? `/${max_retries}` : ""}` : "";
  return `↻ retrying${why ? ` (${why})` : ""}${when}${count}`;
}

// The live turn's status while it waits for plugins' slow setup before its
// first request (plugin_init_wait).
export function initWaitLine({ tasks } = {}) {
  const labels = (tasks || []).map((t) => [t?.bundle, t?.label].filter(Boolean).join(": ")).filter(Boolean);
  return `waiting for ${labels.length ? labels.join(" · ") : "plugins"}…`;
}

// Whether a composer line in an open session is one of its commands
// (+commands+: the session GET's listing), as the terminals decide
// (Commands::Registry#lookup): a "!" line with something after the "!", or
// a listed name alone or followed by a space; a terminal's own (/stats,
// /exit) too, which the page answers itself (webLocalReply). An unknown
// "/word" (a path, a typo) goes to the model as a prompt, as in a terminal.
export function sessionCommandLine(text, commands) {
  const line = String(text || "").trim();
  if (/^!\s*\S/.test(line)) return true;
  if (!line.startsWith("/")) return false;
  if (webLocalReply(line)) return true;
  return (Array.isArray(commands) ? commands : [])
    .some((c) => c && typeof c.name === "string" && (line === c.name || line.startsWith(`${c.name} `)));
}

// A line that is one word: a slash and a name, no spaces, no second slash
// (Commands::Registry#unknown_command_word?). `/modle` is one; `/foo bar`
// and `/usr/bin/env` are not (they are prompts).
const UNKNOWN_COMMAND_WORD = /^\/[A-Za-z][A-Za-z0-9_-]*$/;

// The hint for a command word no command answers (a typo like `/modle`),
// or null when the line is not one: `Unknown command /modle. Did you mean
// /model? /help lists the commands.` The "Did you mean" part needs a close
// name among the session's commands and the page's own (webLocalReply).
export function unknownCommandHint(text, commands) {
  const line = String(text || "").trim();
  if (!UNKNOWN_COMMAND_WORD.test(line)) return null;
  if (sessionCommandLine(line, commands)) return null;
  const names = (Array.isArray(commands) ? commands : [])
    .map((c) => (c && typeof c.name === "string" ? c.name : null))
    .filter(Boolean)
    .concat(Object.keys(WEB_LOCAL_REPLIES));
  const close = closestName(line, names);
  return `Unknown command ${line}. ${close ? `Did you mean ${close}? ` : ""}/help lists the commands.`;
}

// The closest name within an optimal string alignment distance of 2, or
// null. Ties go to the first in the list.
function closestName(line, names) {
  let best = null;
  let bestDistance = 3;
  for (const name of names) {
    const distance = osaDistance(line, name);
    if (distance < bestDistance) {
      best = name;
      bestDistance = distance;
    }
  }
  return best;
}

// Optimal string alignment distance: Levenshtein, with an adjacent
// transposition counting as 1 (so `/modle` is 1 from `/model`, as Ruby's
// DidYouMean reads it).
function osaDistance(a, b) {
  const rows = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j += 1) rows[0][j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      rows[i][j] = Math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        rows[i][j] = Math.min(rows[i][j], rows[i - 2][j - 2] + 1);
      }
    }
  }
  return rows[a.length][b.length];
}

// The terminal's own commands (a button in the web, or none yet): the
// reply the page shows itself (they never go to the worker, which doesn't
// know them), or null.
const WEB_LOCAL_REPLIES = {
  "/archive": "/archive: use the archive button in the session bar",
  "/detach": "/detach: a terminal's command; close the tab to leave, the worker keeps running",
  "/exit": "/exit: close the tab to leave; stop in the session bar stops the worker",
  "/quit": "/quit: close the tab to leave; stop in the session bar stops the worker",
  "/recap": "/recap: not in the web yet; a recap shows here by itself when you come back to an idle session, and /recap in a terminal (chi --attach) makes one now",
  "/stats": "/stats: not in the web yet; each turn shows its time, the session bar the context use and speed (hover ctx for tokens and cost), and /stats in a terminal (chi --attach) has the rest",
};

export function webLocalReply(text) {
  const name = String(text || "").trim().split(/\s+/)[0].toLowerCase();
  return WEB_LOCAL_REPLIES[name] || null;
}

// The start page's first message when the page answers it itself
// (webLocalReply: /stats, /exit …): shown there, with no session made just
// to hold the reply. With images it is a message, as in a session.
export function startPageReply(text, { images = 0 } = {}) {
  return images ? null : webLocalReply(text);
}

// The start page's reply to a first message that needs no session at all
// (2.29): its own command's reply (startPageReply), or the hint for a
// command word no command answers (a typo like /modle) — the hint the page
// shows in a session too, as a command bubble. Decided before the session
// is created, so a first /stats or /modle leaves none behind. A null here
// means the message goes to a session (a prompt, or anything with images).
export function startPageReplyOrHint(text, { commands = [], images = 0 } = {}) {
  if (images) return null;
  return startPageReply(text) || unknownCommandHint(text, commands);
}

// The continue card's answers, as the terminal's continue prompt reads them.
export function continueLine(choice, reason = "") {
  const why = String(reason || "").trim();
  if (choice === "no" && why) return `/continue no, ${why}`;
  return `/continue ${choice}`;
}

// How to show a command_ran: `label` names another client (null for this
// tab's own), `resync` says the conversation changed (!rollback, !cmd, a
// continue answered no) and must be read again. An anytime command's
// (`anytime`, D8) bubble is drawn at its command_queued, before the cards
// it shows; its command_ran fills that bubble in (`commandId`). So is a
// command queued for after the running turn (`queued`): its command_queued
// (waits: "turn_end") draws it `waiting`, saying so, until it ran or was
// dropped (styled as failed).
export const QUEUED_TEXT = "queued: runs after this turn";

export function commandView(event, myId) {
  const own = isOwn(event.client_id, myId);
  const waiting = event.waits === "turn_end";
  return {
    label: own ? null : clientLabel(event.client_id),
    line: event.line || "",
    text: event.output || (waiting ? QUEUED_TEXT : ""),
    busy: event.status === "busy",
    failed: event.status === "error" || event.status === "dropped",
    resync: (event.changed || []).includes("messages"),
    modelName: event.model_name || null,
    anytime: event.anytime === true,
    queued: waiting || event.queued === true,
    waiting,
    commandId: event.command_id || null,
    // A card's action (Nudge…): no bubble unless it says something back.
    hidden: event.card === true && !event.output && event.status !== "error",
  };
}

// What a prompt_restored (the worker rolled a failed turn back and handed its
// prompt back) does in this tab: `refill` is the text for an empty composer,
// only for a prompt this page sent (`sentIds`, its acks' enqueued_ids), so a
// replay after a reload never refills stale text; `own`/`label` mark the
// failed bubble shown again after the resync.
export function restoreAction(event, { myId, sentIds, composerEmpty }) {
  const origin = event?.origin || {};
  const own = isOwn(origin.client_id, myId);
  const sent = own && !!origin.enqueued_id && sentIds.has(origin.enqueued_id);
  // The images go back as chips with the text.
  return withImages({
    refill: sent && composerEmpty ? event.prompt : null,
    own,
    label: own ? null : clientLabel(origin.client_id),
  }, sent && composerEmpty ? event.images : null);
}

// A turn that fails fast can have its prompt_restored come over the stream
// before the /turn ack names its enqueued_id: `early` (a Map) keeps such a
// restore of this tab's own prompt by that id, and the ack takes it back
// (restoreOnAck), so the prompt goes into the composer the ack would clear.
export function keepEarlyRestore(event, early, { myId, sentIds }) {
  const origin = event?.origin || {};
  const id = origin.enqueued_id;
  if (!isOwn(origin.client_id, myId) || !id || sentIds.has(id)) return false;
  early.set(id, event);
  return true;
}

// The ack's enqueued_id (already in sentIds) was restored early: what the
// composer gets back (as restoreAction for an empty composer), else null.
export function restoreOnAck(enqueuedId, early, { myId, sentIds }) {
  const event = enqueuedId && early.get(enqueuedId);
  if (!event) return null;
  early.delete(enqueuedId);
  return restoreAction(event, { myId, sentIds, composerEmpty: true });
}

// The /turn this kept entry was for failed: no ack comes, so nothing would
// take it back. The whole map goes: this tab sends one turn at a time, so
// every entry waits for an ack that is now never coming (an older one is
// left over from a send that failed the same way).
export function dropEarlyRestores(early) {
  const count = early.size;
  early.clear();
  return count;
}

// The composer's text with a restored prompt put back into it: the restored
// text alone when nothing is typed, else the typed text with the restored
// prompt under it (the user typed between the restore and the ack; their
// text must not be replaced).
export function restoreInto(refill, current) {
  const restored = String(refill ?? "");
  const typed = String(current ?? "");
  if (!restored) return typed;
  if (!typed.trim()) return restored;
  return `${typed.replace(/\n+$/, "")}\n${restored}`;
}

// What the composer holds once a /turn ack lands (4.13): the composer still
// carries the text that was just sent, so that text goes (it is the history's
// now) — but text typed since the send stays, and a prompt restored before
// this ack (restoreOnAck's refill) is put back without replacing it.
// @param sent the composer's text when the turn was sent
// @param current the composer's text as the ack lands
// @param refill the prompt an early restore handed back, if any
export function composerAfterAck({ sent = "", current = "", refill = "" } = {}) {
  const kept = String(current ?? "") === String(sent ?? "") ? "" : current;
  return restoreInto(refill, kept);
}

// What an event does to the prompt bubbles, as a list of ops for app.js:
//   add   — a bubble for a prompt this tab hasn't shown (state queued /
//           started / steered, labelled by its sender)
//   tag   — this tab's own local echo gets its enqueued_id
//   start — the bubble's turn started (drops the "queued" badge)
//   steer — the bubble was merged into the running turn
//   report — the merge brought a delegate child's report (origin
//           child:<id8>, no bubble anywhere): its text gets a labelled one
// `known(enqueuedId)` says whether a bubble carries that id already;
// `unmatchedMerge` whether the last input_merged had an origin with no
// bubble ("report": a delegate report's); `wakeStart` whether this is the
// first merge of a turn chi ran for reports (its bubble starts the turn,
// no "steered" badge, as a reload shows it).
export function promptOps(event, { myId, known, unmatchedMerge = false, wakeStart = false }) {
  if (!event) return [];
  switch (event.type) {
    case "turn_enqueued": {
      const id = event.enqueued_id;
      if (isOwn(event.client_id, myId)) return [withImages({ op: "tag", enqueuedId: id, prompt: event.prompt }, event.images)];
      if (id && known(id)) return [];
      return [withImages({ op: "add", enqueuedId: id, prompt: event.prompt, state: "queued", label: clientLabel(event.client_id) }, event.images)];
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
      return [withImages({ op: "add", enqueuedId: id, prompt: event.prompt, state: "started", label: clientLabel(origin.client_id) }, event.images)];
    }
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
    events.push(withImages({ type: "turn_started", prompt: turn.prompt, origin: turn.origin, continue: !!turn.continue, started_at }, turn.images));
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
          const title = part.title ? { title: part.title } : {};
          const view = part.view ? { view: part.view } : {};
          events.push({ type: "tool_call_started", ...call, params: part.params, ...title, ...view });
          if (part.status !== "running") {
            // The activity as the live event had it; action and duration_ms
            // only in snapshots from a worker that keeps them (the TUI's
            // row; the web times rows from the turn's tool records).
            const action = part.action ? { action: part.action } : {};
            const completed = {
              type: "tool_call_completed", ...call, output: part.output, output_truncated: !!part.output_truncated,
              activity: { ...action, tool: part.tool, status: part.status, params: part.params, ...title },
            };
            if (part.duration_ms != null) completed.duration_ms = part.duration_ms;
            if (part.diff) completed.diff = part.diff;
            if (part.view) completed.view = part.view;
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
    events.push(withImages({ type: "turn_enqueued", enqueued_id: entry.enqueued_id, client_id: entry.client_id, prompt: entry.prompt }, entry.images));
  }
  // Commands waiting for the turn's end: their bubbles, as live.
  for (const entry of commands || []) {
    events.push({ type: "command_queued", command_id: entry.command_id, client_id: entry.client_id, line: entry.line, waits: "turn_end" });
  }
  return events;
}

// +object+ with `images` when there are any (the shapes stay as they were
// for a turn without).
function withImages(object, images) {
  return images?.length ? { ...object, images } : object;
}
