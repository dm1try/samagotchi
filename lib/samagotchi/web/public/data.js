import { authProbe, lostAnswer } from "./auth_lost.js";

// What the page does when an answer says the sign-in is gone (auth_lost.js;
// app.js sets it). A no-op until then.
let authLostHandler = () => {};
export function onAuthLost(handler) {
  authLostHandler = typeof handler === "function" ? handler : () => {};
}

// Accept: application/json: an auth proxy whose session ended answers 401
// {} (oauth2-proxy) rather than a redirect to its sign-in. A fetch that
// fails outright asks authProbe whether that was a sign-in redirect.
export function api(path, opts = {}) {
  const { fetchImpl = globalThis.fetch } = opts;
  return fetchImpl(path, {
    ...opts,
    headers: { "Content-Type": "application/json", Accept: "application/json", ...(opts.headers || {}) },
  }).catch((error) => {
    if (error instanceof TypeError) {
      authProbe(fetchImpl).then((state) => { if (state === "lost") authLostHandler(`fetch ${path}`); }, () => {});
    }
    throw error;
  }).then(async (r) => {
    if (lostAnswer(r)) authLostHandler(`${r.status} ${path}`);
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      // The server's words as they are: what the page shows the user. The
      // status goes in only when it sent none (a proxy's bare 502, a crash's
      // 500): then it is all there is to go on.
      const words = j.detail || j.error;
      const error = new Error(words || `${r.statusText || "HTTP error"} (${r.status})`);
      error.status = r.status;
      // The server's error code ({error: "owned_by_tui", detail}): what
      // the page matches on, never the message's words.
      error.code = j.error || null;
      // The whole answer, for what an error carries besides its words (a
      // refused continue's next_id or ids).
      error.body = j;
      throw error;
    }
    return j;
  });
}

// opts.dir: the page's scope folder (scope.js); only that project's sessions.
export function listSessions(sort, order, { dir, ...opts } = {}) {
  const scope = dir ? `&dir=${encodeURIComponent(dir)}` : "";
  return api(
    `/api/sessions?sort=${encodeURIComponent(sort)}&order=${encodeURIComponent(order)}${scope}`,
    opts,
  );
}

// A session with no first turn: the page's first message is sent into it
// as a turn (with its images, once they are uploaded). dir: the folder the
// chat starts in; model: the model it starts on (as GET /api/models spells
// it); either left out means the server's default. preview: that message,
// which names the session until its turn is saved. llm_context: the
// session's own LLM context words ({strategy, apply, budget}), when the
// start page's ⚙ panel set some; thinking: its own level ("low"), when the
// start page's ⚙ panel set one; toolkit: the kit it starts on, when the
// start page's 🧰 list picked one (none: config's default, maybe suggested).
// review: {subjects} makes it a review session (it starts idle; no preview).
// The other fields are api()'s fetch options.
export function createIdleSession({ dir, model, preview, llm_context: llmContext, thinking, toolkit, review,
                                    ...opts } = {}) {
  const start = review ? { review } : { idle: true, ...(preview ? { preview } : {}) };
  const body = { ...start, ...(dir ? { dir } : {}), ...(model ? { model } : {}),
                 ...(llmContext ? { llm_context: llmContext } : {}), ...(thinking ? { thinking } : {}),
                 ...(toolkit ? { toolkit } : {}) };
  return api("/api/sessions", { method: "POST", body: JSON.stringify(body), ...opts });
}

// The next link of +id+'s chain (docs/sessions.md, Session chains): a new
// session in its folder, on its model, starting with its recap, idle (the
// page fills the composer, the user sends); +id+ is archived by it. A
// refusal is api()'s error: code "continued" with body.next_id (the link
// that continues it already), "open_children" with body.ids, …
export function continueSession(id, opts = {}) {
  return api("/api/sessions", { method: "POST", body: JSON.stringify({ continues: id, idle: true }), ...opts });
}

// A review fork of +id+ (docs/sessions.md, Review sessions): a new session in
// its folder, seeded with its recap, not its transcript; +id+ keeps running.
export function startReview(id, opts = {}) {
  return api("/api/sessions", { method: "POST", body: JSON.stringify({ review: { from: id } }), ...opts });
}

// The models a new session can start on: {default, models: [{name, host, id}],
// warning?} (a host that failed is in the warning, the list has the rest).
export function listModels(opts = {}) {
  return api("/api/models", opts);
}

// Update chi to this exact version; progress and component rows arrive as
// `chi_update` events on the page's events stream.
export function updateChi(version, opts = {}) {
  return api("/api/update", { method: "POST", body: JSON.stringify({ version }), ...opts });
}

// Restart every worker running an older chi; results arrive as
// `chi_update` events on the page's events stream.
export function restartWorkers(opts = {}) {
  return api("/api/update/restart_workers", { method: "POST", body: JSON.stringify({}), ...opts });
}

// Ask this chi web to shut down and exec the installed version.
export function restartWeb(opts = {}) {
  return api("/api/update/restart_web", { method: "POST", body: JSON.stringify({}), ...opts });
}

// The prompt history the composer's ↑/↓ walk (the TUI's too), oldest first.
export function fetchHistory(opts = {}) {
  return api("/api/history", opts).then((j) => (Array.isArray(j.entries) ? j.entries : []));
}

// Upload one image (the raw file as the body); answers its ref.
export function uploadImage(id, file, name, opts = {}) {
  return api(`/api/sessions/${id}/images?name=${encodeURIComponent(name || file?.name || "image")}`, {
    method: "POST",
    body: file,
    headers: { "Content-Type": file?.type || "application/octet-stream" },
    ...opts,
  });
}

// opts.tail: the lighter answer for the end of a turn (the session, its
// timing and the last answer only), not the whole history; with
// opts.recent its timing holds the newest turn's records and turn_count
// (mergeTiming), and opts.turnId asks for that turn's answer.
// opts.timing: the whole timing alone (when the merge came up short).
// opts.parts: each saved message with what it did (thinking, tool calls
// and their output), for the turn view's reload.
export function getSession(id, { tail, recent, turnId, timing, parts, cards, ...opts } = {}) {
  let query = cards ? "?cards=1" : tail ? "?tail=1" : timing ? "?timing=1" : parts ? "?parts=1" : "";
  if (tail && recent) query += "&recent=1";
  if (tail && turnId) query += `&turn_id=${encodeURIComponent(turnId)}`;
  return api(`/api/sessions/${id}${query}`, opts);
}

// opts.clientId: this tab's id, so the events tell its prompts from others'.
// opts.images: refs ({file, name}) to images uploaded into the session.
// history: false keeps the prompt out of the shared prompt history (an
// image-only send, whose text is only its [image: …] placeholders).
// delivery: what the message does to a running turn ("cut": /cut TEXT);
// none = the server's default (the next step).
export function sendTurn(id, prompt, { clientId, images, history = true, delivery = null, verify = null, ...opts } = {}) {
  const body = clientId ? { prompt, client_id: clientId } : { prompt };
  if (images?.length) body.images = images;
  if (delivery) body.delivery = delivery;
  if (history === false) body.history = false;
  if (verify) body.verify = verify;
  return api(`/api/sessions/${id}/turn`, {
    method: "POST",
    body: JSON.stringify(body),
    ...opts,
  });
}

// A session command (/model, /models, !rollback, !cmd, /continue …) for the
// worker to run; its command_ran reaches every client.
// card: the line is a card's action (its echo stays out of the history).
export function sendCommand(id, line, { clientId, card = false, ...opts } = {}) {
  return api(`/api/sessions/${id}/command`, {
    method: "POST",
    body: JSON.stringify({ line, ...(clientId ? { client_id: clientId } : {}), ...(card ? { card: true } : {}) }),
    ...opts,
  });
}

// A text's markdown as sanitised HTML ({ html }; null with markdown off).
export function renderText(text, opts = {}) {
  return api("/api/render", {
    method: "POST",
    body: JSON.stringify({ text }),
    ...opts,
  });
}

export function cancelTurn(id, opts = {}) {
  return api(`/api/sessions/${id}/cancel`, {
    method: "POST",
    body: JSON.stringify({ reason: "user" }),
    ...opts,
  });
}

export function sendAnswer(id, answer, opts = {}) {
  return api(`/api/sessions/${id}/answer`, {
    method: "POST",
    body: JSON.stringify(answer),
    ...opts,
  });
}

// Leave the pending question unanswered (the tool returns without one).
export function dismissQuestion(id, questionId, opts = {}) {
  return api(`/api/sessions/${id}/question/dismiss`, {
    method: "POST",
    body: JSON.stringify({ id: questionId }),
    ...opts,
  });
}

// Flags a System 1 auto-allow in this session as one it should have asked
// about; the owner-only route returns 404 for an unknown judgment.
export function markSystemOneWrong(id, judgmentId, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/guardrails/wrong`, {
    method: "POST",
    body: JSON.stringify({ id: judgmentId }),
    ...opts,
  });
}

export function stopSession(id, opts = {}) {
  return api(`/api/sessions/${id}/stop`, { method: "POST", body: JSON.stringify({}), ...opts });
}

// What this session's worker still has that the user can stop (reminders, a
// background task running, a delegate with a live worker), for the Stop
// button's sheet: 200 {holds: []} always — no worker, or one that can't say,
// is an empty list, so Stop stays one tap.
export function sessionHolds(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/holds`, { ...opts });
}

// The sheet's "Stop all": the worker stops everything the user can before the
// Stop TERMs it. 200 {status: "stopped", stopped: {reminders, tasks, delegates}}.
export function stopSessionHolds(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/holds/stop`, { method: "POST", body: JSON.stringify({}), ...opts });
}

// Kills a background task the session's conversation started (the
// stop-task button): 200 {status, stop_reason}; 409 it already ended, 503
// no live worker.
export function stopTask(id, taskId, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/tasks/${encodeURIComponent(taskId)}/stop`, {
    method: "POST",
    body: JSON.stringify({}),
    ...opts,
  });
}

// Takes back a message queued for after the running turn (the × on its
// bubble): 200 {status, enqueued_id, prompt}; 409 already_started /
// not_queued, 404 unknown_enqueued_id, 503 no live worker.
export function dequeueTurn(id, enqueuedId, { clientId = null } = {}, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/turn/${encodeURIComponent(enqueuedId)}/dequeue`, {
    method: "POST",
    body: JSON.stringify(clientId ? { client_id: clientId } : {}),
    ...opts,
  });
}

// Hands the session to a new worker on the newest chi installed: 200
// {status, from_version, version}, or 409 with the reason in words (detail).
export function restartSession(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/restart`, { method: "POST", body: JSON.stringify({}), ...opts });
}

// Hides the session (and its delegates) from the lists, kept for good; the
// server stops a live idle worker first and answers 409 while a turn runs.
export function archiveSession(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/archive`, { method: "POST", body: JSON.stringify({}), ...opts });
}

// Back to the lists, delegates too.
export function unarchiveSession(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/unarchive`, { method: "POST", body: JSON.stringify({}), ...opts });
}

// Deletes the session for good; force=true has the server stop a live
// worker first (the page's confirm says so; without it, 409 worker_running).
export function deleteSession(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}?force=true`, { method: "DELETE", ...opts });
}

// One EventSource listener per handler, named by the handler's key (the
// event type), so a new event type needs only its handler. Each event's
// JSON data goes to its handler (badJson(raw) when it doesn't parse);
// onEvent runs first, for every event.
function listenJson(es, handlers, onEvent, badJson) {
  for (const [type, handler] of Object.entries(handlers)) {
    if (typeof handler !== "function") continue;
    es.addEventListener(type, (raw) => {
      onEvent();
      let data = {};
      try {
        data = raw.data ? JSON.parse(raw.data) : {};
      } catch (_) {
        data = badJson(raw.data);
      }
      handler(data, raw);
    });
  }
}

// fromSeq: the snapshot's event id (`<seq>-<epoch>`: another worker answers it
// with a reset) or a plain event_seq.
export function openStream(id, fromSeq, handlers = {}, opts = {}) {
  const { EventSourceImpl = globalThis.EventSource, onStreamError, onStreamClosed } = opts;
  let cursor = "0";
  if (Number.isInteger(fromSeq)) cursor = String(fromSeq);
  else if (typeof fromSeq === "string" && fromSeq !== "") cursor = encodeURIComponent(fromSeq);
  const es = new EventSourceImpl(`/api/sessions/${id}/stream?from_seq=${cursor}`);
  let eventReceived = false;
  listenJson(es, handlers, () => { eventReceived = true; }, (raw) => ({ text: String(raw) }));
  let live = true;
  es.onerror = () => {
    if (!eventReceived && live && typeof onStreamError === "function") {
      live = false;
      try { es.close(); } catch (_) {}
      onStreamError();
    } else if (eventReceived && live && typeof onStreamClosed === "function") {
      // Don't let the browser reconnect on its own: while there is no
      // worker the proxy answers 503 and the browser gives up (and the next
      // worker would only answer the old Last-Event-ID with a reset). The
      // caller re-reads the session instead.
      live = false;
      try { es.close(); } catch (_) {}
      onStreamClosed();
    }
  };
  return {
    close() {
      if (!live) return;
      live = false;
      try {
        es.close();
      } catch (_) {}
    },
    get live() {
      return live;
    },
    get eventReceived() {
      return eventReceived;
    },
  };
}

// The session list as a stream (GET /api/events): a `snapshot` frame first,
// then `session` (an upsert) and `session_gone` (a removal). onError fires
// only when the browser gave up before the first frame (a chi web without
// a hub answers 503, a bad ?dir 400): the caller falls back to fetching.
// Later errors are left to EventSource's own reconnect, and a reconnect
// always starts with a fresh snapshot, unless the browser gave up for good
// (readyState CLOSED: an auth proxy answered the reconnect with its sign-in
// page): onClosed then, and the caller probes and opens it again.
// @return {{close(): void}}
export function openEvents(handlers = {}, opts = {}) {
  const { EventSourceImpl = globalThis.EventSource, dir, onError, onClosed } = opts;
  const url = dir ? `/api/events?dir=${encodeURIComponent(dir)}` : "/api/events";
  const es = new EventSourceImpl(url);
  let frameReceived = false;
  listenJson(es, handlers, () => { frameReceived = true; }, () => ({}));
  let live = true;
  es.onerror = () => {
    // readyState 2 (CLOSED): the browser won't retry on its own.
    if (!live || es.readyState !== 2) return;
    live = false;
    try { es.close(); } catch (_) {}
    if (!frameReceived) {
      if (typeof onError === "function") onError();
    } else if (typeof onClosed === "function") {
      onClosed();
    }
  };
  return {
    close() {
      if (!live) return;
      live = false;
      try { es.close(); } catch (_) {}
    },
    get live() {
      return live;
    },
  };
}

// A session's working set as the model has it (WorkingSet: {items, at,
// running}), what the stage view's working set overlays on its rows
// (web.working_set).
export function getWorkingSet(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/working_set`, opts);
}

// A session's attached context (chi context): the sources it sees, one
// with its text, and detach (a session's) or mute here (a project's).
export function listContext(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/context`, opts);
}

export function getContext(id, name, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/context/${encodeURIComponent(name)}`, opts);
}

// A URL an installed bundle's provider attaches: {url, why} → {name}.
export function addContext(id, body, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/context`, {
    method: "POST", body: JSON.stringify(body), ...opts,
  });
}

// A session's participants (the owner's panel, participants_panel.js):
// list (with spend and turns), invite (the link once), revoke, cap.
export function listParticipants(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/participants`, opts);
}

export function inviteParticipant(id, body, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/participants`, { method: "POST", body: JSON.stringify(body), ...opts });
}

export function revokeParticipant(id, participantId, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/participants?id=${encodeURIComponent(participantId)}`, { method: "DELETE", ...opts });
}

export function setParticipantCap(id, participantId, cap, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/participants/${encodeURIComponent(participantId)}/cap`, {
    method: "POST", body: JSON.stringify({ cap }), ...opts,
  });
}

export function detachContext(id, name, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}/context/${encodeURIComponent(name)}`, { method: "DELETE", ...opts });
}
