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

// A decode speed: "87 tok/s", "1.9k tok/s"; "~64 tok/s" for an estimate (no
// server timings); "" without one. The TUI's /stats says the same
// (Formatting#speed_text; spec/shared/labels_matrix.json).
export function speedText(tps, source) {
  const value = num(tps);
  if (value === null || value <= 0) return "";
  const number = value >= 1000 ? `${Math.round(value / 100) / 10}k` : String(Math.round(value));
  return `${source === "estimate" ? "~" : ""}${number} tok/s`;
}

// A cost in USD: "$0.42"; under a cent, four decimals ("$0.0012"); "" for
// none or zero. As Formatting#cost_text.
export function costText(cost) {
  const value = num(cost);
  if (value === null || value <= 0) return "";
  return value >= 0.01 ? `$${value.toFixed(2)}` : `$${value.toFixed(4)}`;
}

function count(n) {
  return Math.round(n).toLocaleString("en-US");
}

// The ctx tooltip (info bar and card): +title+, then the session's tokens
// (in summed over every request, cached with its share, out with the
// reasoning part) and its cost, when it has any. A delegated session keeps
// its own metrics, so these are this session's only.
export function tokensTipText(tokens, title = "Context used after the last turn") {
  const prompt = num(tokens?.prompt_sum) || 0;
  const completion = num(tokens?.completion_sum) || 0;
  if (!prompt && !completion) return title;
  const cached = num(tokens.cached_sum) || 0;
  const reasoning = num(tokens.reasoning_sum) || 0;
  const parts = [`in ${count(prompt)}`];
  if (cached > 0 && prompt > 0) parts.push(`cached ${count(cached)} (${Math.round((cached * 100) / prompt)}%)`);
  parts.push(`out ${count(completion)}${reasoning > 0 ? ` (reasoning ${count(reasoning)})` : ""}`);
  const lines = [title, `tokens: ${parts.join(" · ")}`];
  const cost = costText(tokens.cost_sum);
  if (cost) lines.push(`cost: ${cost}`);
  lines.push("this session only, all requests");
  return lines.join("\n");
}

// The info bar's speed: the newest generation's decode speed, "" before one.
export function lastSpeedText(tokens) {
  return speedText(tokens?.last_decode_tps, tokens?.tps_source);
}
