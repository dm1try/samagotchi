const DEFAULT_EVENT_TYPES = Object.freeze([
  "generation_chunk",
  "generation_started",
  "generation_completed",
  "turn_started",
  "turn_completed",
  "turn_canceled",
  "tool_call_completed",
  "tool_call_started",
  "context_status",
  "used_memories_updated",
  "pending_input_merged",
  "reset",
  "question_requested",
  "question_answered",
  "question_cancelled",
]);

export function api(path, opts = {}) {
  const { fetchImpl = globalThis.fetch } = opts;
  return fetchImpl(path, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  }).then(async (r) => {
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`${j.detail || j.error || r.statusText} (${r.status})`);
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

export function getSession(id, opts = {}) {
  return api(`/api/sessions/${id}`, opts);
}

export function sendTurn(id, prompt, opts = {}) {
  return api(`/api/sessions/${id}/turn`, {
    method: "POST",
    body: JSON.stringify({ prompt }),
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

export function stopSession(id, opts = {}) {
  return api(`/api/sessions/${id}/stop`, { method: "POST", body: JSON.stringify({}), ...opts });
}

export function openStream(id, fromSeq, handlers = {}, opts = {}) {
  const { EventSourceImpl = globalThis.EventSource, onStreamError } = opts;
  const seq = Number.isInteger(fromSeq) ? fromSeq : 0;
  const es = new EventSourceImpl(`/api/sessions/${id}/stream?from_seq=${seq}`);
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
