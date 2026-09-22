import test from "node:test";
import assert from "node:assert/strict";
import { extractCtxPct } from "../../../lib/samagotchi/web/public/ctx.js";

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
