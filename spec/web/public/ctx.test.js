import test from "node:test";
import assert from "node:assert/strict";
import {
  extractCtxPct, savedCtxPct, cardCtxText, ctxBarText, ctxWindowText, speedText, costText, tokensTipText, lastSpeedText, generationTokens,
} from "../../../lib/samagotchi/web/public/ctx.js";

// Final /completion chunk from our llama.cpp (trimmed): counts, no n_ctx.
const llamaFinal = { stop: true, tokens_evaluated: 120, tokens_predicted: 30, timings: { prompt_n: 3, predicted_n: 30 } };

test("uses the resolved window when the payload has no n_ctx", () => {
  assert.equal(extractCtxPct({ payload: llamaFinal }, 1000), 15);
});

test("returns null without any window", () => {
  assert.equal(extractCtxPct({ payload: llamaFinal }), null);
});

test("a window the payload reports wins over the resolved one", () => {
  assert.equal(extractCtxPct({ payload: { ...llamaFinal, n_ctx: 300 } }, 1000), 50);
});

test("prefers n_past, then usage totals", () => {
  assert.equal(extractCtxPct({ payload: { n_past: 500, tokens_evaluated: 1 } }, 1000), 50);
  assert.equal(extractCtxPct({ payload: { usage: { total_tokens: 250 } } }, 1000), 25);
});

test("passes a precomputed pct through", () => {
  assert.equal(extractCtxPct({ est_pct: 42.5 }, 1000), 42.5);
  assert.equal(extractCtxPct({ ctx_pct: 7 }), 7);
});

test("ignores chunks without token counts", () => {
  assert.equal(extractCtxPct({ payload: { content: "hi" } }, 1000), null);
});

// Shape of the kernel's :context_status event (kernel_loop emit_context_status_event).
test("reads usage.estimated_pct from a context_status event", () => {
  const event = {
    type: "context_status", iteration: 1, status: "ctx 12% (ok)", bucket: "ok", source: "estimate",
    usage: { window_tokens: 32768, window_source: "props", estimated_used_tokens: 3932,
             estimated_remaining_tokens: 28836, estimated_pct: 12.0, source: "estimate" },
  };
  assert.equal(extractCtxPct(event), 12.0);
  assert.equal(extractCtxPct(event, 1000), 12.0);
});

test("savedCtxPct: the saved context's fill, null without both counts", () => {
  assert.equal(savedCtxPct({ used_tokens: 250, window_tokens: 1000, window_source: "server" }), 25);
  assert.equal(savedCtxPct({ used_tokens: 250, window_tokens: null }), null);
  assert.equal(savedCtxPct({ used_tokens: null, window_tokens: 1000 }), null);
  assert.equal(savedCtxPct(null), null);
});

test("savedCtxPct: counted against the LLM context budget when it is smaller than the window, as live", () => {
  const context = { used_tokens: 16000, window_tokens: 128000, window_source: "server" };
  assert.equal(savedCtxPct(context, 64000), 25);
  assert.equal(savedCtxPct(context, 256000), 12.5);
  assert.equal(savedCtxPct(context, null), 12.5);
  assert.equal(savedCtxPct({ used_tokens: 16000, window_tokens: null }, 64000), null);
});

test("extractCtxPct: a fill computed here counts against a smaller budget; a precomputed one passes through", () => {
  assert.equal(extractCtxPct({ payload: { usage: { total_tokens: 250 } } }, 1000, 500), 50);
  assert.equal(extractCtxPct({ payload: { n_ctx: 300, n_past: 150 } }, 1000, 600), 50);
  assert.equal(extractCtxPct({ payload: { usage: { total_tokens: 250 } } }, 1000, 4000), 25);
  assert.equal(extractCtxPct({ usage: { estimated_pct: 40 } }, 1000, 500), 40);
});

test("cardCtxText: a rounded percentage, empty when unknown", () => {
  assert.equal(cardCtxText(12.4), "12%");
  assert.equal(cardCtxText(0.2), "0%");
  assert.equal(cardCtxText(null), "");
  assert.equal(cardCtxText(undefined), "");
});

test("speedText: the server's speed as is, an estimate with ~, thousands as k, nothing without one", () => {
  assert.equal(speedText(87.46, "server"), "87 tok/s");
  assert.equal(speedText(64.4, "estimate"), "~64 tok/s");
  assert.equal(speedText(1904.2, "server"), "1.9k tok/s");
  assert.equal(speedText(null, "server"), "");
  assert.equal(speedText(0, "server"), "");
});

test("costText: cents, or four decimals under a cent; nothing for none or zero", () => {
  assert.equal(costText(0.4213), "$0.42");
  assert.equal(costText(0.00123), "$0.0012");
  assert.equal(costText(0), "");
  assert.equal(costText(undefined), "");
});

test("tokensTipText: in with its cached share, out with reasoning, the cost; this session only", () => {
  const tokens = { prompt_sum: 5210, completion_sum: 340, cached_sum: 4864, reasoning_sum: 212, cost_sum: 0.00123 };
  assert.equal(tokensTipText(tokens), [
    "Context used after the last turn",
    "tokens: in 5,210 · cached 4,864 (93%) · out 340 (reasoning 212)",
    "cost: $0.0012",
    "this session only, all requests",
  ].join("\n"));
});

test("tokensTipText: an estimated cost (hosts.<name>.models prices) shows with ~, apart from a reported one", () => {
  const tokens = { prompt_sum: 1000, completion_sum: 40, cost_sum: 0.42, cost_estimate_sum: 0.12 };
  assert.equal(tokensTipText(tokens, "ctx").split("\n")[2], "cost: ~$0.54 ($0.42 reported, ~$0.12 estimated)");
  assert.equal(tokensTipText({ ...tokens, cost_sum: 0 }, "ctx").split("\n")[2], "cost: ~$0.12 (estimated)");
  assert.equal(tokensTipText({ ...tokens, cost_estimate_sum: 0 }, "ctx").split("\n")[2], "cost: $0.42");
});

test("tokensTipText: a live snapshot from an older worker, and an older saved summary, have no estimate key", () => {
  const live = { prompt_sum: 1000, completion_sum: 40, cached_sum: 0, cost_sum: 0.42, last_decode_tps: 50 };
  assert.equal(tokensTipText(live, "ctx").split("\n")[2], "cost: $0.42");
  const saved = { prompt_sum: 1000, completion_sum: 40, cached_sum: 0, reasoning_sum: 0, cost_sum: 0 };
  assert.equal(tokensTipText(saved, "ctx"), "ctx\ntokens: in 1,000 · out 40\nthis session only, all requests");
});

test("tokensTipText: a local session has no cached or cost line; no tokens leaves the title alone", () => {
  assert.equal(tokensTipText({ prompt_sum: 300, completion_sum: 56, cached_sum: 0, cost_sum: 0 }, "ctx"),
    "ctx\ntokens: in 300 · out 56\nthis session only, all requests");
  assert.equal(tokensTipText(null), "Context used after the last turn");
  assert.equal(tokensTipText({ prompt_sum: 0, completion_sum: 0 }, "ctx"), "ctx");
});

test("tokensTipText: the memory indexes the session's prompt holds, last; none without the block", () => {
  const memoryIndex = { system: { tokens: 1997, lines: 54 }, project: { tokens: 1394, lines: 35 } };
  const line = "memory index: ~3.4k tokens in this session's prompt (system 2.0k, project 1.4k)";
  assert.equal(tokensTipText({ prompt_sum: 300, completion_sum: 56 }, "ctx", memoryIndex),
    `ctx\ntokens: in 300 · out 56\nthis session only, all requests\n${line}`);
  assert.equal(tokensTipText(null, undefined, memoryIndex), `Context used after the last turn\n${line}`);
  assert.equal(tokensTipText(null, "ctx", null), "ctx");
  assert.equal(tokensTipText(null, "ctx", {}), "ctx");
});

test("lastSpeedText: the newest generation's speed from the tokens block", () => {
  assert.equal(lastSpeedText({ last_decode_tps: 31.6, tps_source: "server" }), "32 tok/s");
  assert.equal(lastSpeedText({ last_decode_tps: 80, tps_source: "estimate" }), "~80 tok/s");
  assert.equal(lastSpeedText(null), "");
});

test("generationTokens: the event's totals with its speed; an event without them keeps the page's", () => {
  const previous = { prompt_sum: 10, completion_sum: 2, last_decode_tps: 50, tps_source: "server" };
  const totals = { prompt_sum: 300, completion_sum: 40, last_decode_tps: 50, tps_source: "server" };
  assert.deepEqual(generationTokens(previous, { tokens: totals, speed: { decode_tps: 80, source: "estimate" } }),
    { ...totals, last_decode_tps: 80, tps_source: "estimate" });
  // A generation too short for a speed: the totals' last speed stands.
  assert.deepEqual(generationTokens(previous, { tokens: totals, speed: null }), totals);
  assert.deepEqual(generationTokens(previous, { type: "generation_completed" }), previous);
  assert.equal(generationTokens(undefined, {}), null);
});

test("ctxBarText: the percent; ~ when the window is chi's default guess", () => {
  assert.equal(ctxBarText(12.4, "server"), "ctx 12%");
  assert.equal(ctxBarText(12.4, null), "ctx 12%");
  assert.equal(ctxBarText(12.4, "default"), "ctx ~12%");
  assert.equal(ctxBarText(null, "default"), "");
});

test("ctxWindowText: used of window with its source; the default says it's a guess", () => {
  assert.equal(ctxWindowText({ tokens: 128000, source: "server", pct: 32 }), "context: ~41.0k of 128.0k tokens (server)");
  assert.equal(ctxWindowText({ tokens: 256000, source: "default", pct: 10 }),
    "context: ~25.6k of 256.0k tokens (chi's default, a guess: set window_tokens for this model)");
  assert.equal(ctxWindowText({ tokens: 32768, source: "model_setting", pct: null }), "context: 32.8k tokens (model_setting)");
  assert.equal(ctxWindowText({ tokens: null, source: "server", pct: 5 }), "");
  assert.equal(ctxWindowText(null), "");
});

test("ctxWindowText: under a smaller budget, used of the budget and the window", () => {
  assert.equal(ctxWindowText({ tokens: 128000, source: "server", pct: 25, budget: 64000 }),
    "context: ~16.0k of the 64.0k budget, 128.0k window (server)");
  assert.equal(ctxWindowText({ tokens: 128000, source: "server", pct: 25, budget: 256000 }),
    "context: ~32.0k of 128.0k tokens (server)");
  assert.equal(ctxWindowText({ tokens: 128000, source: null, pct: null, budget: 64000 }),
    "context: the 64.0k budget, 128.0k window");
});

test("tokensTipText: the window line under the title", () => {
  assert.equal(tokensTipText({ prompt_sum: 300, completion_sum: 56 }, "ctx", null, { tokens: 1000, source: "config", pct: 35.6 }),
    "ctx\ncontext: ~356 of 1.0k tokens (config)\ntokens: in 300 · out 56\nthis session only, all requests");
  assert.equal(tokensTipText(null, "ctx", null, { tokens: 1000, source: "config", pct: null }), "ctx\ncontext: 1.0k tokens (config)");
});
