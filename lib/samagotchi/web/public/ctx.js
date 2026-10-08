// Context-window usage (%) from a stream event. `windowTokens` is the window
// the kernel resolved for this generation (:generation_started carries it as
// context_window_tokens); llama.cpp's stream payloads report token counts
// but no n_ctx, so without it only a precomputed pct or an n_ctx works.
// `budgetTokens` is the session's LLM context budget (llm_context's
// budget_tokens): a percentage this file computes counts against it when it
// is smaller than the window, as the kernel's :context_status does
// (ContextStatus#counted_against), so the meter reads the same from either.

function num(v) {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

// What a fill counts against: the window, or the budget when one is set
// and smaller; null without a window.
export function countedTokens(windowTokens, budgetTokens = null) {
  const window = num(windowTokens);
  if (!window || window <= 0) return null;
  const budget = num(budgetTokens);
  return budget && budget > 0 ? Math.min(budget, window) : window;
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

export function extractCtxPct(data, windowTokens = null, budgetTokens = null) {
  if (!data || typeof data !== "object") return null;
  if (num(data.ctx_pct) !== null) return data.ctx_pct;
  if (num(data.est_pct) !== null) return data.est_pct;
  if (num(data.ctxPct) !== null) return data.ctxPct;
  // The kernel's :context_status event: { usage: { estimated_pct, ... }, bucket }.
  if (num(data.usage?.estimated_pct) !== null) return data.usage.estimated_pct;
  if (data.context_window_tokens && data.total_tokens) {
    const against = countedTokens(data.context_window_tokens, budgetTokens);
    if (against) return (data.total_tokens / against) * 100;
  }
  const p = data.payload || data;
  if (num(p.ctx_pct) !== null) return p.ctx_pct;
  const against = countedTokens(num(p.n_ctx) || num(windowTokens), budgetTokens);
  const used = usedTokens(p);
  if (!against || used === null) return null;
  return (used / against) * 100;
}

// The saved context (the session's timing.context: used_tokens after the
// last counted turn, the window now): the meter's value on load, before a
// turn streams, counted against +budgetTokens+ (the session's llm_context
// budget_tokens) when it is smaller, as live. null when either count is
// missing.
export function savedCtxPct(context, budgetTokens = null) {
  const used = num(context?.used_tokens);
  const against = countedTokens(context?.window_tokens, budgetTokens);
  if (used === null || !against) return null;
  return (used / against) * 100;
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
  const number = value >= 1000 ? `${(Math.round(value / 100) / 10).toFixed(1)}k` : String(Math.round(value));
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

// A token count as the size readouts word it: "450", "2.0k". As
// MemoryBundle::IndexSize.count_text.
function countK(n) {
  return n >= 1000 ? `${(Math.round(n / 100) / 10).toFixed(1)}k` : String(Math.round(n));
}

// "~3.4k tokens in this session's prompt (system 2.0k, project 1.4k)": the
// memory indexes the session's prompt holds (the snapshot's memory_index,
// measured when the prompt was built); "" without one. As
// Formatting#memory_index_text (spec/shared/labels_matrix.json).
export function memoryIndexText(memoryIndex) {
  if (!memoryIndex || typeof memoryIndex !== "object") return "";
  const scopes = ["system", "project"]
    .map((scope) => [scope, num(memoryIndex[scope]?.tokens)])
    .filter(([, tokens]) => tokens !== null);
  if (!scopes.length) return "";
  const total = scopes.reduce((sum, [, tokens]) => sum + tokens, 0);
  return `~${countK(total)} tokens in this session's prompt (${scopes.map(([scope, tokens]) => `${scope} ${countK(tokens)}`).join(", ")})`;
}

// The info bar's ctx: "ctx 12%", "ctx ~12%" when the window is chi's
// default (no server, model list or setting gave one, so the percent is of
// a guess); "" without a pct.
export function ctxBarText(pct, windowSource = null) {
  if (num(pct) === null) return "";
  return `ctx ${windowSource === "default" ? "~" : ""}${Math.round(pct)}%`;
}

// The ctx tooltip's window line ({tokens:, source:, pct:, budget:} the
// session's window, where it came from, the meter's value and the LLM
// context budget): "context: ~41.0k of 128.0k tokens (server)", as /stats
// names the source; under a budget smaller than the window the meter's
// percentage is of the budget: "context: ~41.0k of the 64.0k budget,
// 128.0k window (server)"; "" without a window.
export function ctxWindowText(window) {
  const tokens = num(window?.tokens);
  if (!tokens || tokens <= 0) return "";
  const against = countedTokens(tokens, window.budget);
  const pct = num(window.pct);
  const source = window.source === "default"
    ? "chi's default, a guess: set window_tokens for this model"
    : window.source;
  const sourceText = source ? ` (${source})` : "";
  if (against < tokens) {
    const used = pct === null ? "" : `~${countK((pct / 100) * against)} of `;
    return `context: ${used}the ${countK(against)} budget, ${countK(tokens)} window${sourceText}`;
  }
  const used = pct === null ? "" : `~${countK((pct / 100) * tokens)} of `;
  return `context: ${used}${countK(tokens)} tokens${sourceText}`;
}

// The ctx tooltip (info bar and card): +title+, then the session's tokens
// (in summed over every request, cached with its share, out with the
// reasoning part) and its cost, when it has any, and the memory indexes
// its prompt holds (+memoryIndex+, the snapshot's memory_index); with
// +window+ (ctxWindowText's) the window line under the title. A
// delegated session keeps its own metrics, so these are this session's only.
export function tokensTipText(tokens, title = "Context used after the last turn", memoryIndex = null, window = null) {
  const memory = memoryIndexText(memoryIndex);
  const memoryLine = memory ? `\nmemory index: ${memory}` : "";
  const windowText = ctxWindowText(window);
  if (windowText) title = `${title}\n${windowText}`;
  const prompt = num(tokens?.prompt_sum) || 0;
  const completion = num(tokens?.completion_sum) || 0;
  if (!prompt && !completion) return `${title}${memoryLine}`;
  const cached = num(tokens.cached_sum) || 0;
  const reasoning = num(tokens.reasoning_sum) || 0;
  const parts = [`in ${count(prompt)}`];
  if (cached > 0 && prompt > 0) parts.push(`cached ${count(cached)} (${Math.round((cached * 100) / prompt)}%)`);
  parts.push(`out ${count(completion)}${reasoning > 0 ? ` (reasoning ${count(reasoning)})` : ""}`);
  const lines = [title, `tokens: ${parts.join(" · ")}`];
  const cost = costText(tokens.cost_sum);
  if (cost) lines.push(`cost: ${cost}`);
  lines.push("this session only, all requests");
  return `${lines.join("\n")}${memoryLine}`;
}

// The info bar's speed: the newest generation's decode speed, "" before one.
export function lastSpeedText(tokens) {
  return speedText(tokens?.last_decode_tps, tokens?.tps_source);
}

// The session's tokens block after a :generation_completed: the event's
// running totals (the server closed the generation and put them on it),
// with its speed; an event without them (a replay, an older worker) keeps
// +previous+.
export function generationTokens(previous, data) {
  const tokens = data?.tokens;
  if (!tokens || typeof tokens !== "object") return previous ?? null;
  const speed = data.speed;
  if (!speed || num(speed.decode_tps) === null) return tokens;
  return { ...tokens, last_decode_tps: speed.decode_tps, tps_source: speed.source };
}
