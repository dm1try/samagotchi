export const PREVIEW_CHARS = 40;
export const FIRST_PREVIEW_CHARS = 80;

export function escapeHtml(value) {
  return String(value).replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]),
  );
}

export function messageBodyHtml(message) {
  if (message?.role === "assistant" && typeof message.html === "string") {
    return { body: message.html, renderedMarkdown: true };
  }
  if (message?.role === "user") return { body: userBodyHtml(message.content), renderedMarkdown: false };
  return { body: escapeHtml(message?.content), renderedMarkdown: false };
}

// A context note (background the user or another session pushed in; the
// model reads it, nobody asked it anything): who sent it, then its text.
export function noteHtml(note) {
  const from = note?.label ? `note from ${note.label}` : "note";
  return `<div class="note-line">${escapeHtml(from)}</div><div class="note-text">${escapeHtml(note?.content ?? "")}</div>`;
}

// A user message's body: runs of `>` lines become <blockquote>s, the rest
// stays escaped text. The bubble is pre-wrap, so the blank lines around a
// quote are dropped (the blockquote's margin spaces it instead).
export function userBodyHtml(content) {
  const text = String(content ?? "").replace(/\r\n?/g, "\n");
  const blocks = [];
  for (const line of text.split("\n")) {
    const m = /^ {0,3}> ?(.*)$/.exec(line);
    const kind = m ? "quote" : "text";
    const last = blocks[blocks.length - 1];
    if (last?.kind === kind) last.lines.push(m ? m[1] : line);
    else blocks.push({ kind, lines: [m ? m[1] : line] });
  }
  if (!blocks.some((b) => b.kind === "quote")) return escapeHtml(content ?? "");
  return blocks
    .map((b) => {
      if (b.kind === "quote") return `<blockquote>${escapeHtml(b.lines.join("\n"))}</blockquote>`;
      const body = b.lines.join("\n").replace(/^\s*\n/, "").replace(/\n\s*$/, "");
      return body.trim() ? escapeHtml(body) : "";
    })
    .join("");
}

export function normalize(s) {
  return String(s || "").replace(/\s+/g, " ").trim();
}

export function previewOf(lastPrompt) {
  const normalized = normalize(lastPrompt);
  if (!normalized) return "\u2014";
  if (normalized.length > PREVIEW_CHARS) {
    return `${normalized.slice(0, PREVIEW_CHARS)}\u2026`;
  }
  return normalized;
}

export function firstMessageOf(session, messages) {
  // Prefer first user message content, else last_prompt / first_preview from server
  if (Array.isArray(messages) && messages.length) {
    const firstUser = messages.find((m) => m && (m.role === "user" || m.role === "assistant") && m.role === "user");
    if (firstUser && firstUser.content) {
      const n = normalize(firstUser.content);
      if (n) return n.length > FIRST_PREVIEW_CHARS ? `${n.slice(0, FIRST_PREVIEW_CHARS)}\u2026` : n;
    }
  }
  if (session) {
    if (session.first_preview) {
      const n = normalize(session.first_preview);
      if (n) return n;
    }
    if (session.last_prompt) return previewOf(session.last_prompt);
    // fallback to previewOf with first_preview logic length 80
    const raw = session.preview || session.id || "";
    const n = normalize(raw);
    if (n) return n.length > FIRST_PREVIEW_CHARS ? `${n.slice(0, FIRST_PREVIEW_CHARS)}\u2026` : n;
  }
  return "\u2014";
}

export function previewForCard(session) {
  // Unified card preview: first message (80) else previewOf(last_prompt)
  const raw = session.first_preview || session.last_prompt || "";
  const n = normalize(raw);
  if (!n) return "\u2014";
  if (n.length > FIRST_PREVIEW_CHARS) return `${n.slice(0, FIRST_PREVIEW_CHARS)}\u2026`;
  return n;
}

const DELETE_PREVIEW_CHARS = 40;

// The confirm before deleting a session (the info bar's and a card's).
export function deleteConfirmText(session) {
  const n = normalize(session.first_preview || session.last_prompt || "");
  const preview = n.length > DELETE_PREVIEW_CHARS ? `${n.slice(0, DELETE_PREVIEW_CHARS)}\u2026` : n;
  const shortId = session.short_id || String(session.id).slice(0, 8);
  const lines = [
    `Delete session ${shortId}${preview ? ` \u2014 "${preview}"` : ""}?`,
    "Its history, notes and images are removed; this can't be undone.",
  ];
  if (session.owner === "worker") lines.push("Its worker is running and will be stopped first.");
  return lines.join("\n");
}

// The badge on a session a process holds right now (the list's `owner`):
// a worker (shared: every UI can send), or a plain terminal chi (not shared).
export function ownerBadge(owner, id) {
  if (owner === "worker") {
    return { kind: "worker", text: "live", title: `A worker runs this session; a terminal joins with: chi --attach ${id}` };
  }
  if (owner === "tui") {
    return { kind: "tui", text: "terminal", title: "A terminal chi owns this session and doesn't share it (chi --shared would)" };
  }
  return null;
}

// The line a failed turn's bubble shows: a provider error's one-line
// summary, else the error's message and class.
export function failedTurnText(data) {
  data = data || {};
  const detail = data.summary || `${data.message || "error"}${data.error_class ? ` (${data.error_class})` : ""}`;
  return `\u2715 turn failed: ${detail}`;
}

// Whether the server served another model than asked: names equal in any
// case, or one extending the other (":free" dropped, a date added), are the
// same model (ServedModel.differs? in Ruby).
export function servedModelDiffers(asked, served) {
  const a = String(asked || "").trim().toLowerCase();
  const s = String(served || "").trim().toLowerCase();
  if (!a || !s) return false;
  return !(a.startsWith(s) || s.startsWith(a));
}

// The session's model for the info bar: the served model with a marker when
// the server serves another one than +servedFor+ (the name asked).
export function modelLabel(model, served, servedFor) {
  if (servedModelDiffers(servedFor, served)) {
    return { text: `${served.slice(0, 40)} ⚠`, title: `served: ${served}; asked for ${model}`, mismatch: true };
  }
  const name = model || "";
  return { text: name.slice(0, 40), title: name, mismatch: false };
}
