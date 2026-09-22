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

// This tab's id in the events (`origin.client_id`, turn_enqueued's
// client_id): new per page load, like the TUI's `tui:<pid>`.
export function newClientId() {
  return `web:${Math.random().toString(36).slice(2, 10).padEnd(8, "0")}`;
}

export function isOwn(clientId, myId) {
  return clientId != null && clientId === myId;
}

const CLIENT_LABELS = Object.freeze({ tui: "tui", web: "web", system: "reminder" });

// The label on another client's prompt, by its client_id prefix.
export function clientLabel(clientId) {
  if (!clientId) return null;
  return CLIENT_LABELS[String(clientId).split(":", 1)[0]] || "user";
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
      if (isOwn(event.client_id, myId)) return [{ op: "tag", enqueuedId: id, prompt: event.prompt }];
      if (id && known(id)) return [];
      return [{ op: "add", enqueuedId: id, prompt: event.prompt, state: "queued", label: clientLabel(event.client_id) }];
    }
    case "turn_started": {
      if (event.continue || !event.prompt) return [];
      const origin = event.origin || {};
      const id = origin.enqueued_id || null;
      if ((id && known(id)) || isOwn(origin.client_id, myId)) {
        return [{ op: "start", enqueuedId: id, prompt: event.prompt }];
      }
      return [{ op: "add", enqueuedId: id, prompt: event.prompt, state: "started", label: clientLabel(origin.client_id) }];
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
