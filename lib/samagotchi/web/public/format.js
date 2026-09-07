export const PREVIEW_CHARS = 40;
export const FIRST_PREVIEW_CHARS = 80;

export function escapeHtml(value) {
  return String(value).replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]),
  );
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
