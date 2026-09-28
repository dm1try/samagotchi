// Context-window usage (%) from a stream event. `windowTokens` is the window
// the kernel resolved for this generation (:generation_started carries it as
// context_window_tokens); llama.cpp's stream payloads report token counts
// but no n_ctx, so without it only a precomputed pct or an n_ctx works.

function num(v) {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

// Tokens in context after this chunk: prompt + generated so far.
function usedTokens(p) {
  if (!p || typeof p !== "object") return null;
  if (num(p.n_past)) return p.n_past;
  if (num(p.usage?.total_tokens)) return p.usage.total_tokens;
  const prompt = num(p.usage?.prompt_tokens) ?? num(p.tokens_evaluated) ?? num(p.timings?.prompt_n);
  const completion = num(p.usage?.completion_tokens) ?? num(p.tokens_predicted) ?? num(p.timings?.predicted_n);
  if (prompt === null && completion === null) return null;
  return (prompt ?? 0) + (completion ?? 0);
}

export function extractCtxPct(data, windowTokens = null) {
  if (!data || typeof data !== "object") return null;
  if (num(data.ctx_pct) !== null) return data.ctx_pct;
  if (num(data.est_pct) !== null) return data.est_pct;
  if (num(data.ctxPct) !== null) return data.ctxPct;
  // The kernel's :context_status event: { usage: { estimated_pct, ... }, bucket }.
  if (num(data.usage?.estimated_pct) !== null) return data.usage.estimated_pct;
  if (data.context_window_tokens && data.total_tokens) return (data.total_tokens / data.context_window_tokens) * 100;
  const p = data.payload || data;
  if (num(p.ctx_pct) !== null) return p.ctx_pct;
  const window = num(p.n_ctx) || num(windowTokens);
  const used = usedTokens(p);
  if (!window || window <= 0 || used === null) return null;
  return (used / window) * 100;
}

// The saved context (the session's timing.context: used_tokens after the
// last counted turn, the window now): the meter's value on load, before a
// turn streams. null when either count is missing.
export function savedCtxPct(context) {
  const used = num(context?.used_tokens);
  const window = num(context?.window_tokens);
  if (used === null || !window || window <= 0) return null;
  return (used / window) * 100;
}

// A session card's quiet ctx: "12%", or "" when the list row has none.
export function cardCtxText(pct) {
  return num(pct) === null ? "" : `${Math.round(pct)}%`;
}
