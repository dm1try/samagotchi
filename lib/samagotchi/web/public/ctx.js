// Context-window usage (%) from a stream event: a :context_status's
// estimated_pct, or a :generation_chunk's `counts` (chi's own counts, which
// the worker's Bridge works out from the provider's payload; the payload
// itself never reaches a client). `windowTokens` is the window the kernel
// resolved for this generation (:generation_started carries it as
// context_window_tokens); a chunk's counts carry a window only when the server
// reported one (llama.cpp's /completion doesn't), and that one wins.
// `budgetTokens` is the session's LLM context budget (llm_context's
// budget_tokens): a percentage this file computes counts against it when it
// is smaller than the window, as the kernel's :context_status does
// (ContextStatus#counted_against), so the meter reads the same from either.

function num(v) {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

// What a fill counts against: the window, or the budget when one is set
// and smaller; null without a window.
function countedTokens(windowTokens, budgetTokens = null) {
  const window = num(windowTokens);
  if (!window || window <= 0) return null;
  const budget = num(budgetTokens);
  return budget && budget > 0 ? Math.min(budget, window) : window;
}

export function extractCtxPct(data, windowTokens = null, budgetTokens = null) {
  if (!data || typeof data !== "object") return null;
  // The kernel's :context_status event: { usage: { estimated_pct, ... }, bucket }.
  if (num(data.usage?.estimated_pct) !== null) return data.usage.estimated_pct;
  // A chunk's counts: tokens in context after it (prompt + generated so far).
  const counts = data.counts;
  if (!counts || typeof counts !== "object") return null;
  const used = num(counts.total_tokens);
  const against = countedTokens(num(counts.context_window_tokens) || num(windowTokens), budgetTokens);
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

// A session card's quiet ctx: "12%", "ctx ?" when the list row has none (the
// chip is always shown; "ctx ?" never means 0 — no request in this session
// yet; a lone "?" beside the folder would read as "? project").
export function cardCtxText(pct) {
  return num(pct) === null ? "ctx ?" : `${Math.round(pct)}%`;
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

// A cost in USD: "$0.42"; under a cent, four decimals ("$0.0012"); "~$0.12"
// for an estimate (hosts.<name>.models prices); "" for none or zero. As
// Formatting#cost_text.
export function costText(cost, { estimate = false } = {}) {
  const value = num(cost);
  if (value === null || value <= 0) return "";
  return `${estimate ? "~" : ""}${value >= 0.01 ? `$${value.toFixed(2)}` : `$${value.toFixed(4)}`}`;
}

// The ctx tooltip's cost: the reported cost as is; with an estimate (an
// older worker or saved file has none) the total with "~" and both parts.
function costLine(tokens) {
  const reported = num(tokens.cost_sum) || 0;
  const estimated = num(tokens.cost_estimate_sum) || 0;
  if (estimated <= 0) return reported > 0 ? `cost: ${costText(reported)}` : "";
  const total = costText(reported + estimated, { estimate: true });
  const parts = reported > 0 ? `${costText(reported)} reported, ${costText(estimated, { estimate: true })} estimated` : "estimated";
  return `cost: ${total} (${parts})`;
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
// a guess); "ctx ?" when there is no percent yet (no request in this session
// — the chip is always shown; "?" never means 0).
export function ctxBarText(pct, windowSource = null) {
  if (num(pct) === null) return "ctx ?";
  return `ctx ${windowSource === "default" ? "~" : ""}${Math.round(pct)}%`;
}

// The info bar's / the card's ctx tooltip: the window line under the title
// when there's a number (tokensTipText), or why there's none when the page
// has no percent: "No request in this session yet" before any request (the
// page isn't told context.status is off, so "?" never means 0); after one,
// "Context window unknown" over the session's tokens and per-model rows with
// no window line (a window lookup that failed; a model list without a context
// length still falls back to context.window_tokens or chi's default). +window.afterSwitch+ (the info
// bar's; a /model whose new window didn't resolve, no request since:
// Engine#announce_switched_context! sent usage null) adds "until the next
// request", which asks for it again.
// +side+ (the timing's side block) adds the side requests' line, in the
// "No request in this session yet" answer too (a /btw before any turn).
export function ctxBarTip(tokens, memoryIndex, window, segments = null, side = null) {
  if (num(window?.pct) === null) {
    if (!num(tokens?.prompt_sum) && !num(tokens?.completion_sum)) {
      const sideText = sideRequestsText(side);
      return `No request in this session yet${sideText ? `\nside requests: ${sideText}` : ""}`;
    }
    const why = window?.afterSwitch ? "Context window unknown until the next request" : "Context window unknown";
    return tokensTipText(tokens, why, memoryIndex, null, segments, side);
  }

  return tokensTipText(tokens, undefined, memoryIndex, window, segments, side);
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

// ── A session's rows per model (the timing's modelSegments) ──────────────
// The words /stats' models: block shares (Formatting#model_segment_*;
// spec/shared/labels_matrix.json model_segments).

// A row's model: its ref; the rows folded past the cap ("3 earlier
// segments", told by folded_segments); a session's turns from before turns
// named their model ("earlier turns").
export function modelSegmentLabel(row) {
  const folded = num(row?.folded_segments);
  if (folded !== null && folded > 0) return `${folded} earlier segments`;
  return row?.model_ref ? String(row.model_ref) : "earlier turns";
}

// "6.0k in / 40 out".
export function modelSegmentTokensText(row) {
  return `${countK(num(row?.prompt_sum) || 0)} in / ${countK(num(row?.completion_sum) || 0)} out`;
}

// "$0.42", "~$0.12", "$0.42 + ~$0.12"; "" for none.
export function modelSegmentCostText(row) {
  return [costText(row?.cost_sum), costText(row?.cost_estimate_sum, { estimate: true })].filter(Boolean).join(" + ");
}

// "3 (recap 2, btw 1) · 14.2k in / 380 out · $0.0012 + ~$0.0009": the
// session's side requests (the timing's side block: the idle recap, /btw and
// other ctx.ask_model calls, apart from its turns' totals), the kinds in
// first-seen order (one kind: its name alone), then the model rows' tokens
// and cost words on the block; "" without any (the line is hidden). As
// Formatting#side_requests_text (spec/shared/labels_matrix.json side_requests).
export function sideRequestsText(side) {
  if (!side || typeof side !== "object") return "";
  const requests = num(side.requests) || 0;
  if (requests <= 0) return "";
  const kinds = side.by_kind && typeof side.by_kind === "object" ? Object.entries(side.by_kind) : [];
  const names = kinds.length === 1
    ? kinds[0][0]
    : kinds.map(([kind, row]) => `${kind} ${Math.round(num(row?.requests) || 0)}`).join(", ");
  const head = names ? `${Math.round(requests)} (${names})` : String(Math.round(requests));
  return [head, modelSegmentTokensText(side), modelSegmentCostText(side)].filter(Boolean).join(" · ");
}

// "switch prefill 3.0k uncached prompt ≈$0.0060": what the switch to the
// row's model prefilled (its cost an estimate from the configured price,
// left out without one); "" for none.
export function modelSegmentPrefillText(row) {
  const tokens = num(row?.prefill_tokens) || 0;
  if (tokens <= 0) return "";
  const cost = costText(row?.prefill_cost_estimate);
  return `switch prefill ${countK(tokens)} uncached prompt${cost ? ` ≈${cost}` : ""}`;
}

// A ref past +max+ characters with its middle cut to one "…":
// the tooltip is a native title, which grows as wide as its longest line.
// The host's start and the model's end stay; the model chip has the full ref.
const TIP_REF_MAX = 40;
export function shortRef(text, max = TIP_REF_MAX) {
  const chars = [...text];
  if (chars.length <= max) return text;
  const head = Math.floor((max - 1) / 3);
  return `${chars.slice(0, head).join("")}…${chars.slice(chars.length - (max - 1 - head)).join("")}`;
}

// The tooltip's rows per model, with ≥ 2 (one model: none): "model ·
// turns · in / out · cost", a switch's prefill under its row.
function modelSegmentLines(segments) {
  if (!Array.isArray(segments) || segments.length < 2) return [];
  const lines = ["per model:"];
  for (const row of segments) {
    const turns = num(row.turns) || 0;
    const parts = [shortRef(modelSegmentLabel(row)), `${turns} ${turns === 1 ? "turn" : "turns"}`, modelSegmentTokensText(row)];
    const cost = modelSegmentCostText(row);
    if (cost) parts.push(cost);
    lines.push(`  ${parts.join(" · ")}`);
    const prefill = modelSegmentPrefillText(row);
    if (prefill) lines.push(`    └ ${prefill}`);
  }
  return lines;
}

// The ctx tooltip (info bar and card): +title+, then the session's tokens
// (in summed over every request, cached with its share, out with the
// reasoning part) and its cost, when it has any (an estimated part with
// "~", costLine), and the memory indexes
// its prompt holds (+memoryIndex+, the snapshot's memory_index); with
// +window+ (ctxWindowText's) the window line under the title; with
// +segments+ (the timing's modelSegments, ≥ 2) the rows per model above the
// totals. A delegated session keeps its own metrics, so these are this
// session's only.
export function tokensTipText(tokens, title = "Context used after the last turn", memoryIndex = null, window = null,
                              segments = null, side = null) {
  const memory = memoryIndexText(memoryIndex);
  const memoryLine = memory ? `\nmemory index: ${memory}` : "";
  const sideText = sideRequestsText(side);
  const sideLine = sideText ? `side requests: ${sideText}` : "";
  const windowText = ctxWindowText(window);
  if (windowText) title = `${title}\n${windowText}`;
  const prompt = num(tokens?.prompt_sum) || 0;
  const completion = num(tokens?.completion_sum) || 0;
  if (!prompt && !completion) return `${title}${sideLine ? `\n${sideLine}` : ""}${memoryLine}`;
  const cached = num(tokens.cached_sum) || 0;
  const reasoning = num(tokens.reasoning_sum) || 0;
  const parts = [`in ${count(prompt)}`];
  if (cached > 0 && prompt > 0) parts.push(`cached ${count(cached)} (${Math.round((cached * 100) / prompt)}%)`);
  parts.push(`out ${count(completion)}${reasoning > 0 ? ` (reasoning ${count(reasoning)})` : ""}`);
  const lines = [title, ...modelSegmentLines(segments), `tokens: ${parts.join(" · ")}`];
  const cost = costLine(tokens);
  if (cost) lines.push(cost);
  if (sideLine) lines.push(sideLine);
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
