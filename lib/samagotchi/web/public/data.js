const DEFAULT_EVENT_TYPES = Object.freeze([
  "generation_chunk",
  "generation_started",
  "generation_completed",
  "turn_started",
  "turn_completed",
  "turn_canceled",
  "turn_failed",
  "turn_enqueued",
  "input_merged",
  "tool_call_completed",
  "tool_call_started",
  "context_status",
  "used_memories_updated",
  "pending_input_merged",
  "reset",
  "question_requested",
  "question_answered",
  "question_cancelled",
  "recap_ready",
  "prompt_restored",
  "command_ran",
  "continue_offered",
  "continue_resolved",
  "reminder_injected",
  "context_added",
  "guardrail_warning",
]);

export function api(path, opts = {}) {
  const { fetchImpl = globalThis.fetch } = opts;
  return fetchImpl(path, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  }).then(async (r) => {
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      const error = new Error(`${j.detail || j.error || r.statusText} (${r.status})`);
      error.status = r.status;
      throw error;
    }
    return j;
  });
}

export function listSessions(sort, order, opts = {}) {
  return api(
    `/api/sessions?sort=${encodeURIComponent(sort)}&order=${encodeURIComponent(order)}`,
    opts,
  );
}

export function createSession(prompt, opts = {}) {
  return api("/api/sessions", { method: "POST", body: JSON.stringify({ prompt }), ...opts });
}

// A session with no first turn: a first message with images is sent into
// it once they are uploaded.
export function createIdleSession(opts = {}) {
  return api("/api/sessions", { method: "POST", body: JSON.stringify({ idle: true }), ...opts });
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

export function getSession(id, opts = {}) {
  return api(`/api/sessions/${id}`, opts);
}

// opts.clientId: this tab's id, so the events tell its prompts from others'.
// opts.images: refs ({file, name}) to images uploaded into the session.
export function sendTurn(id, prompt, { clientId, images, ...opts } = {}) {
  const body = clientId ? { prompt, client_id: clientId } : { prompt };
  if (images?.length) body.images = images;
  return api(`/api/sessions/${id}/turn`, {
    method: "POST",
    body: JSON.stringify(body),
    ...opts,
  });
}

// A session command (/model, /models, !rollback, !cmd, /continue …) for the
// worker to run; its command_ran reaches every client.
export function sendCommand(id, line, { clientId, ...opts } = {}) {
  return api(`/api/sessions/${id}/command`, {
    method: "POST",
    body: JSON.stringify(clientId ? { line, client_id: clientId } : { line }),
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

export function stopSession(id, opts = {}) {
  return api(`/api/sessions/${id}/stop`, { method: "POST", body: JSON.stringify({}), ...opts });
}

// Deletes the session for good; the server stops a live worker first.
export function deleteSession(id, opts = {}) {
  return api(`/api/sessions/${encodeURIComponent(id)}`, { method: "DELETE", ...opts });
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
  for (const type of DEFAULT_EVENT_TYPES) {
    const handler = handlers[type];
    if (!handler) continue;
    es.addEventListener(type, (raw) => {
      eventReceived = true;
      let data = {};
      try {
        data = raw.data ? JSON.parse(raw.data) : {};
      } catch (_) {
        data = { text: String(raw.data) };
      }
      handler(data, raw);
    });
  }
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

// Poll a session that has no live worker until one shows up (another client
// enqueued a turn or a command, which woke it), then hand its data to
// onLive once. A page without a stream would otherwise never see that turn.
// @return {{stop(): void}}
export function watchForWorker(id, opts = {}) {
  const {
    getSessionImpl = getSession,
    onLive,
    interval = 3000,
    setTimeoutImpl = globalThis.setTimeout,
    clearTimeoutImpl = globalThis.clearTimeout,
  } = opts;
  let stopped = false;
  let timer = null;
  const poll = async () => {
    timer = null;
    if (stopped) return;
    let data = null;
    try {
      data = await getSessionImpl(id);
    } catch (_) {
      data = null;
    }
    if (stopped) return;
    if (data && typeof data.last_event_seq === "number") {
      stopped = true;
      onLive(data);
      return;
    }
    timer = setTimeoutImpl(poll, interval);
  };
  timer = setTimeoutImpl(poll, interval);
  return {
    stop() {
      stopped = true;
      if (timer !== null) clearTimeoutImpl(timer);
      timer = null;
    },
  };
}
