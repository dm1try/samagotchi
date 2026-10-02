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
// null when no turn was running.
export function workerGoneText({ turnRunning, stopped = false }) {
  if (!turnRunning) return null;
  return `\u2715 canceled (${stopped ? "session stopped" : "worker exited"})`;
}

// This tab's id in the events (`origin.client_id`, turn_enqueued's
// client_id): new per page load, like the TUI's `tui:<pid>`.
export function newClientId() {
  return `web:${Math.random().toString(36).slice(2, 10).padEnd(8, "0")}`;
}

export function isOwn(clientId, myId) {
  return clientId != null && clientId === myId;
}

// As the TUI labels them (Formatting::CLIENT_LABELS); this file's label
// helpers and the TUI's agree per spec/shared/labels_matrix.json.
const CLIENT_LABELS = Object.freeze({ tui: "tui", web: "web", system: "reminder", delegate: "delegate" });

// The label on another client's prompt, by its client_id prefix.
export function clientLabel(clientId) {
  if (!clientId) return null;
  return CLIENT_LABELS[String(clientId).split(":", 1)[0]] || "user";
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
// after a plugin cut the generation (stopped_by: the bundle).
export function emptyRetryLine({ attempt, of, stopped_by: stoppedBy } = {}) {
  const what = stoppedBy ? `cut by ${stoppedBy}` : "empty answer";
  return `↻ ${what}, asking again (${attempt}/${of})`;
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

// A composer line for the worker's command route rather than a prompt.
export function isCommandLine(text) {
  return /^[/!]/.test(String(text || "").trim());
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
  "/stats": "/stats: not in the web yet; each turn shows its time and the context use, and /stats in a terminal (chi --attach) has the totals",
};

export function webLocalReply(text) {
  const name = String(text || "").trim().split(/\s+/)[0].toLowerCase();
  return WEB_LOCAL_REPLIES[name] || null;
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
// it shows; its command_ran fills that bubble in (`commandId`).
export function commandView(event, myId) {
  const own = isOwn(event.client_id, myId);
  return {
    label: own ? null : clientLabel(event.client_id),
    line: event.line || "",
    text: event.output || "",
    busy: event.status === "busy",
    failed: event.status === "error",
    resync: (event.changed || []).includes("messages"),
    modelName: event.model_name || null,
    anytime: event.anytime === true,
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

// What an event does to the prompt bubbles, as a list of ops for app.js:
//   add   — a bubble for a prompt this tab hasn't shown (state queued /
//           started / steered, labelled by its sender)
//   tag   — this tab's own local echo gets its enqueued_id
//   start — the bubble's turn started (drops the "queued" badge)
//   steer — the bubble was merged into the running turn
// `known(enqueuedId)` says whether a bubble carries that id already;
// `unmatchedMerge` whether the last input_merged had an origin with no bubble.
export function promptOps(event, { myId, known, unmatchedMerge = false }) {
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
    case "input_merged":
      return (event.origins || []).filter((o) => o && o.enqueued_id).map((o) =>
        known(o.enqueued_id) ? { op: "steer", enqueuedId: o.enqueued_id } : { op: "steer", enqueuedId: o.enqueued_id, unmatched: true },
      );
    case "pending_input_merged":
      if (!unmatchedMerge || !event.content) return [];
      return [{ op: "add", enqueuedId: null, prompt: event.content, state: "steered", label: null }];
    default:
      return [];
  }
}

// A session view from the server (GET /api/sessions/:id on a live worker)
// as the live events that would have drawn it: the turn in progress (its
// parts in order), then the prompts queued behind it. app.js feeds these to
// its stream handlers, so a join renders exactly like watching live.
// `merged_input` is the one synthetic type: a prompt merged into the turn.
// A `notice` part carries its event as it came (TurnNotice). The TUI replays
// a turn the same way (TurnAccumulator.replay_events); spec/shared/
// turn_snapshot.json pins both.
export function snapshotEvents({ current_turn: turn = null, queued = [], started_at = undefined } = {}) {
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
          events.push({ type: "tool_call_started", ...call, params: part.params, ...title });
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
  return events;
}

// +object+ with `images` when there are any (the shapes stay as they were
// for a turn without).
function withImages(object, images) {
  return images?.length ? { ...object, images } : object;
}
