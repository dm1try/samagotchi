import test from "node:test";
import assert from "node:assert/strict";
import { pickModel, MODEL_KEY } from "../../../lib/samagotchi/web/public/model_pick.js";

const named = (...names) => names.map((name) => ({ name }));
const names = named("Gemma-4B-it", "Qwen3-14B", "box:gemma4-26b");

test("pickModel prefers the remembered choice while it is offered, else the default", () => {
  assert.equal(pickModel(names, "Gemma-4B-it", "box:gemma4-26b"), "box:gemma4-26b");
  assert.equal(pickModel(names, "Gemma-4B-it", "BOX:GEMMA4-26B"), "box:gemma4-26b");
  assert.equal(pickModel(names, "Gemma-4B-it", "gone:model"), "Gemma-4B-it");
  assert.equal(pickModel(names, "Gemma-4B-it", null), "Gemma-4B-it");
  assert.equal(pickModel(names, "Gemma-4B-it", ""), "Gemma-4B-it");
});

test("pickModel falls back to the default even when no host lists it, then to the first name", () => {
  assert.equal(pickModel(named("a", "b"), "zzz", null), "zzz");
  assert.equal(pickModel(named("a", "b"), null, null), "a");
  assert.equal(pickModel([], null, "x"), "");
});

test("pickModel keeps a remembered or default name whose host is down; only the last fallback skips one", () => {
  const rows = [{ name: "down:rr/x", unavailable: true }, { name: "a" }];
  assert.equal(pickModel(rows, "a", "down:rr/x"), "down:rr/x");
  assert.equal(pickModel(rows, "down:rr/x", null), "down:rr/x");
  assert.equal(pickModel(rows, null, null), "a");
  assert.equal(pickModel(rows.slice(0, 1), null, null), "down:rr/x");
});

test("the storage key is stable", () => {
  assert.equal(MODEL_KEY, "chi_model");
});

import {
  modelRows, groupRows, matchModels, RECENT_KEY, pushRecent, recentRows, rowNote, rowTitle,
} from "../../../lib/samagotchi/web/public/model_pick.js";

const orPayload = {
  default: "qwen3.6-35b",
  models: [
    { name: "qwen3.6-35b", host: "llama", id: "qwen3.6-35b" },
    { name: "gemma-4b", host: "llama", id: "gemma-4b" },
    { name: "openrouter:~anthropic/claude-opus-latest", host: "openrouter", id: "~anthropic/claude-opus-latest" },
    { name: "openrouter:deepseek/deepseek-v4.1", host: "openrouter", id: "deepseek/deepseek-v4.1" },
    { name: "openrouter:deepseek/deepseek-v4.1-flash", host: "openrouter", id: "deepseek/deepseek-v4.1-flash" },
    { name: "openrouter:deepseek/deepseek-v4.1-flash-lite", host: "openrouter", id: "deepseek/deepseek-v4.1-flash-lite" },
    { name: "openrouter:anthropic/claude-sonnet-5.5", host: "openrouter", id: "anthropic/claude-sonnet-5.5" },
    { name: "openrouter:qwen/qwen3.6-35b", host: "openrouter", id: "qwen/qwen3.6-35b" },
    { name: "openrouter:mistral/codestral-flash", host: "openrouter", id: "mistral/codestral-flash" },
  ],
};
const rows = modelRows(orPayload);
const ids = (matches) => matches.map((m) => `${m.row.isDefaultHost ? "" : `${m.row.host} · `}${m.row.id}`);
const cut = (text, marks) => marks.map(([a, b]) => text.slice(a, b));

test("modelRows gives name, host, id and whether the row is the default host's", () => {
  assert.deepEqual(rows[0], { name: "qwen3.6-35b", host: "llama", id: "qwen3.6-35b", isDefaultHost: true });
  assert.deepEqual(rows[4], {
    name: "openrouter:deepseek/deepseek-v4.1-flash", host: "openrouter",
    id: "deepseek/deepseek-v4.1-flash", isDefaultHost: false,
  });
  assert.deepEqual(modelRows(null), []);
  assert.deepEqual(modelRows({ models: [{ name: "" }, { name: "a", host: "h", id: "a" }] }).map((r) => r.name), ["a"]);
});

test("modelRows carries a model's configured sampling", () => {
  const r = modelRows({ models: [{ name: "work:q", host: "work", id: "q", sampling: "temperature=0.6 (hosts.work)" }] });
  assert.equal(r[0].sampling, "temperature=0.6 (hosts.work)");
});

test("modelRows keeps a model's LLM context summary, and none that isn't one", () => {
  const summary = { strategy: "stale", strategy_source: "model_setting", strategy_where: "models: q" };
  const r = modelRows({ models: [{ name: "q", id: "q", llm_context: summary }, { name: "p", id: "p", llm_context: "stale" }] });
  assert.deepEqual(r[0].llm_context, summary);
  assert.equal("llm_context" in r[1], false);
});

test("modelRows keeps a model's thinking summary, and none that isn't one", () => {
  const summary = { level: "off", source: "models: q", own: null };
  const r = modelRows({ models: [{ name: "q", id: "q", thinking: summary }, { name: "p", id: "p", thinking: "off" }] });
  assert.deepEqual(r[0].thinking, summary);
  assert.equal("thinking" in r[1], false);
});

test("modelRows puts the server's unshifted default (host nil) in the default group, shown by its name", () => {
  const r = modelRows({ default: "openrouter:x", models: [
    { name: "openrouter:x", host: null, id: "openrouter:x" },
    { name: "llama-a", host: "llama", id: "llama-a" },
  ] });
  assert.deepEqual(r[0], { name: "openrouter:x", host: "", id: "openrouter:x", isDefaultHost: true });
  const groups = groupRows(r);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].host, "llama");
  assert.deepEqual(groups[0].rows.map((x) => x.id), ["llama-a", "openrouter:x"]);
});

test("groupRows keeps the hosts' order, the default host first, ids A-Z inside a host", () => {
  const groups = groupRows(rows);
  assert.deepEqual(groups.map((g) => [g.host, g.isDefault]), [["llama", true], ["openrouter", false]]);
  assert.deepEqual(groups[0].rows.map((r) => r.id), ["gemma-4b", "qwen3.6-35b"]);
  assert.deepEqual(groups[1].rows.map((r) => r.id), [
    "~anthropic/claude-opus-latest", "anthropic/claude-sonnet-5.5", "deepseek/deepseek-v4.1",
    "deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash-lite", "mistral/codestral-flash",
    "qwen/qwen3.6-35b",
  ]);
  assert.equal(groupRows([{ name: "d", host: "", id: "d", isDefaultHost: true }])[0].host, "default");
});

test("the user's 'deepseek4.1 fla' finds the v4.1 flash first", () => {
  const m = matchModels(rows, "deepseek4.1 fla");
  assert.deepEqual(ids(m), ["openrouter · deepseek/deepseek-v4.1-flash", "openrouter · deepseek/deepseek-v4.1-flash-lite"]);
  assert.deepEqual(cut(m[0].row.id, m[0].idMarks), ["deepseek", "4.1", "fla"]);
  assert.deepEqual(m[0].hostMarks, []);
});

test("'v4.1 flash' and 'openrouter deepseek' work, the host words marking the host", () => {
  assert.equal(ids(matchModels(rows, "v4.1 flash"))[0], "openrouter · deepseek/deepseek-v4.1-flash");
  const m = matchModels(rows, "openrouter deepseek");
  assert.deepEqual(ids(m), [
    "openrouter · deepseek/deepseek-v4.1", "openrouter · deepseek/deepseek-v4.1-flash",
    "openrouter · deepseek/deepseek-v4.1-flash-lite",
  ]);
  assert.deepEqual(cut("openrouter", m[0].hostMarks), ["openrouter"]);
  assert.deepEqual(cut(m[0].row.id, m[0].idMarks), ["deepseek"]);
});

test("a default-host row matched through its hidden host gets no host marks", () => {
  const m = matchModels(rows, "llama gemma");
  assert.deepEqual(ids(m), ["gemma-4b"]);
  assert.deepEqual(m[0].hostMarks, []);
  assert.deepEqual(cut("gemma-4b", m[0].idMarks), ["gemma"]);
});

test("a match at a segment start beats one mid-segment", () => {
  // The segment start wins although that id is the longer one.
  const r = [
    { name: "h:x/abcode", host: "h", id: "x/abcode", isDefaultHost: false },
    { name: "h:x/code-ab", host: "h", id: "x/code-ab", isDefaultHost: false },
  ];
  assert.deepEqual(matchModels(r, "code").map((x) => x.row.id), ["x/code-ab", "x/abcode"]);
});

test("every word must match", () => {
  assert.deepEqual(matchModels(rows, "deepseek sonnet"), []);
  assert.deepEqual(matchModels(rows, "zzz"), []);
});

test("a subsequence match ranks below a substring one; short words need a substring", () => {
  const r = [
    { name: "h:fxlxaxsxh", host: "h", id: "fxlxaxsxh", isDefaultHost: false },
    { name: "h:y-flash", host: "h", id: "y-flash-long-name", isDefaultHost: false },
  ];
  assert.deepEqual(matchModels(r, "flash").map((x) => x.row.id), ["y-flash-long-name", "fxlxaxsxh"]);
  assert.deepEqual(matchModels(r, "fx").map((x) => x.row.id), ["fxlxaxsxh"]);
  assert.deepEqual(matchModels(r, "fl").map((x) => x.row.id), ["y-flash-long-name"]);
});

test("the shorter id wins a tie, then the no-query order", () => {
  assert.deepEqual(ids(matchModels(rows, "flash")).slice(0, 2), [
    "openrouter · mistral/codestral-flash", "openrouter · deepseek/deepseek-v4.1-flash",
  ]);
});

test("an empty or blank query matches nothing to rank (the caller shows the groups)", () => {
  assert.deepEqual(matchModels(rows, "   "), []);
});

test("marks never overlap and line up with the shown text, case-insensitively", () => {
  const m = matchModels(rows, "DeepSeek deep");
  assert.deepEqual(cut(m[0].row.id, m[0].idMarks), ["deepseek"]);
});

test("the recent list: newest first, no duplicates (any case), capped, only offered names", () => {
  assert.equal(RECENT_KEY, "chi_model_recent");
  assert.deepEqual(pushRecent(["a", "b"], "c"), ["c", "a", "b"]);
  assert.deepEqual(pushRecent(["a", "B", "c"], "b"), ["b", "a", "c"]);
  assert.deepEqual(pushRecent(["1", "2", "3", "4", "5"], "6"), ["6", "1", "2", "3", "4"]);
  assert.deepEqual(pushRecent(null, "x"), ["x"]);
  assert.deepEqual(pushRecent(["x"], ""), ["x"]);
  const rec = recentRows(rows, ["gone:model", "OPENROUTER:deepseek/deepseek-v4.1-flash", "qwen3.6-35b", 7]);
  assert.deepEqual(rec.map((r) => r.name), ["openrouter:deepseek/deepseek-v4.1-flash", "qwen3.6-35b"]);
  assert.deepEqual(recentRows(rows, "junk"), []);
});

test("modelRows marks a row configured (declared under hosts.<name>.models) only when the server says so", () => {
  const r = modelRows({ models: [{ name: "work:rr/x", host: "work", id: "rr/x", configured: true },
                                 { name: "work:a", host: "work", id: "a" }] });
  assert.equal(r[0].configured, true);
  assert.equal("configured" in r[1], false);
});

test("groupRows puts a host's configured ids first, each part A-Z", () => {
  const r = modelRows({ models: [
    { name: "work:a", host: "work", id: "a" },
    { name: "work:rr/z", host: "work", id: "rr/z", configured: true },
    { name: "work:b", host: "work", id: "b" },
    { name: "work:rr/y", host: "work", id: "rr/y", configured: true },
  ] });
  assert.deepEqual(groupRows(r)[0].rows.map((row) => row.id), ["rr/y", "rr/z", "a", "b"]);
});

test("rowNote says default for the default, config for a configured row, default when both", () => {
  const configured = { name: "work:rr/x", host: "work", id: "rr/x", configured: true };
  assert.equal(rowNote(configured, "gemma"), "config");
  assert.equal(rowNote(configured, "work:rr/x"), "default");
  assert.equal(rowNote({ name: "gemma", host: "", id: "gemma" }, "gemma"), "default");
  assert.equal(rowNote({ name: "work:a", host: "work", id: "a" }, "gemma"), "");
});

test("rowTitle joins the sampling tooltip and where a configured row comes from", () => {
  assert.equal(rowTitle({ host: "work", configured: true, sampling: "temperature=0.6 (hosts.work)" }),
    "sampling: temperature=0.6 (hosts.work); served by config (hosts.work.models)");
  assert.equal(rowTitle({ host: "work", configured: true }), "served by config (hosts.work.models)");
  assert.equal(rowTitle({ host: "work", sampling: "top_p=0.9" }), "sampling: top_p=0.9");
  assert.equal(rowTitle({ host: "work" }), "");
  const both = { name: "work:rr/x", host: "work", id: "rr/x", configured: true };
  assert.equal(rowNote(both, "work:rr/x"), "default");
  assert.equal(rowTitle(both), "served by config (hosts.work.models)");
});

test("modelRows marks a row unavailable (its host failed to list) only when the server says so", () => {
  const r = modelRows({ models: [{ name: "down:rr/x", host: "down", id: "rr/x", configured: true, unavailable: true },
                                 { name: "work:a", host: "work", id: "a", unavailable: "yes" }] });
  assert.equal(r[0].unavailable, true);
  assert.equal("unavailable" in r[1], false);
});

test("groupRows marks a host unavailable only when every row of it is", () => {
  const r = modelRows({ models: [
    { name: "a", host: "llama", id: "a" },
    { name: "down:rr/x", host: "down", id: "rr/x", configured: true, unavailable: true },
    { name: "down:rr/y", host: "down", id: "rr/y", configured: true, unavailable: true },
  ] });
  assert.deepEqual(groupRows(r).map((g) => [g.host, g.unavailable]), [["llama", false], ["down", true]]);
});

test("rowNote and rowTitle say a row's host is down", () => {
  const down = { name: "down:rr/x", host: "down", id: "rr/x", configured: true, unavailable: true };
  assert.equal(rowNote(down, "gemma"), "config · host down");
  assert.equal(rowNote(down, "down:rr/x"), "default · host down");
  assert.equal(rowTitle(down),
    "served by config (hosts.down.models); host down didn't list its models (down?); a chat on it may fail");
});
