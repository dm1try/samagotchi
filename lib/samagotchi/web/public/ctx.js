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
  if (data.context_window_tokens && data.total_tokens) return (data.total_tokens / data.context_window_tokens) * 100;
  const p = data.payload || data;
  if (num(p.ctx_pct) !== null) return p.ctx_pct;
  const window = num(p.n_ctx) || num(windowTokens);
  const used = usedTokens(p);
  if (!window || window <= 0 || used === null) return null;
  return (used / window) * 100;
}
