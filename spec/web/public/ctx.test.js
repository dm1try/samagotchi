import test from "node:test";
import assert from "node:assert/strict";
import { extractCtxPct, savedCtxPct, cardCtxText } from "../../../lib/samagotchi/web/public/ctx.js";

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

test("cardCtxText: a rounded percentage, empty when unknown", () => {
  assert.equal(cardCtxText(12.4), "12%");
  assert.equal(cardCtxText(0.2), "0%");
  assert.equal(cardCtxText(null), "");
  assert.equal(cardCtxText(undefined), "");
});
