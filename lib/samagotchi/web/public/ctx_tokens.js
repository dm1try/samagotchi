// The context's token count, next to its % (ctx.js): what the working set's
// head view says is in chi's head ("~X of Y") and what its Conversation row is
// the rest of. The same data ctx.js extractCtxPct reads: a :context_status's
// usage.estimated_used_tokens, a :generation_chunk's counts.total_tokens; on
// load the live worker's newest % back into tokens, else the saved
// timing.context.used_tokens.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

// The tokens in context a stream event says (+data+: a :context_status or a
// :generation_chunk), null when it says none.
export function ctxTokensOf(data) {
  if (!data || typeof data !== "object") return null;
  const used = num(data.usage?.estimated_used_tokens);
  if (used !== null) return used;
  return num(data.counts?.total_tokens);
}

// On load: the live worker's newest % (+pct+, counted against the window or
// the smaller budget) as tokens when the window is known, else the saved
// count (+context+: the session's timing.context). null when neither is.
export function loadedCtxTokens({ pct = null, context = null, budgetTokens = null } = {}) {
  const window = num(context?.window_tokens);
  if (num(pct) !== null && window && window > 0) {
    const budget = num(budgetTokens);
    const against = budget && budget > 0 ? Math.min(budget, window) : window;
    return Math.round((pct / 100) * against);
  }
  return num(context?.used_tokens);
}
