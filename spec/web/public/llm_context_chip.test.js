import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  BUDGET_ERROR, choiceWords, commandLine, mergeChoice, ownValues, parseBudget, strategyValue,
} from "../../../lib/samagotchi/web/public/llm_context_chip.js";

const fromModel = {
  strategy: "stale", strategy_source: "model_setting", strategy_where: "models: qwen",
  apply: "payoff", apply_source: "config", apply_where: "llm_context.apply",
  budget_tokens: null, budget_source: "config", budget_where: "llm_context.budget_tokens", own: null,
};
const own = {
  ...fromModel, strategy: "stale,forget", strategy_source: "session", strategy_where: "the session",
  budget_tokens: 64000, budget_source: "session", budget_where: "the session",
  own: { strategy: ["stale", "forget"], budget_tokens: 64000 },
};

test("the session's own values as the panel reads them, default for the unset ones", () => {
  assert.deepEqual(ownValues(fromModel), { strategy: "default", apply: "default", budget: "" });
  assert.deepEqual(ownValues(own), { strategy: "stale,forget", apply: "default", budget: "64000" });
  assert.deepEqual(ownValues({ own: { strategy: [], budget_tokens: 0 } }), { strategy: "none", apply: "default", budget: "off" });
});

test("a strategy is one value in chi's order (stale before forget); none for no layers", () => {
  assert.equal(strategyValue(["forget", "stale"]), "stale,forget");
  assert.equal(strategyValue([]), "none");
  assert.deepEqual(ownValues({ own: { strategy: ["forget"] } }), { strategy: "forget", apply: "default", budget: "" });
});

test("Set sends only the fields the user changed, so a value it left alone is never unset, with --yes (the form states the cost)", () => {
  const initial = ownValues({ own: { strategy: ["forget"], budget_tokens: 64000 } });
  assert.equal(commandLine({ strategy: "forget", apply: "turn_end", budget: "64000" }, initial), "/llm-context apply turn_end --yes");
  assert.equal(commandLine({ strategy: "forget", apply: "default", budget: "" }, initial), "/llm-context budget default --yes");
  assert.equal(commandLine({ ...initial }, initial), null);
});

test("the command sets every field, default for the ones left to the model; all default is a reset", () => {
  assert.equal(commandLine({ strategy: "stale,forget", apply: "turn_end", budget: " 64k " }),
               "/llm-context strategy stale,forget apply turn_end budget 64k --yes");
  assert.equal(commandLine({ strategy: "none", apply: "default", budget: "" }),
               "/llm-context strategy none apply default budget default --yes");
  assert.equal(commandLine({}), "/llm-context reset --yes");
});

test("a Set merges the changed fields into the choice; default drops one; nothing left is no choice", () => {
  const blank = ownValues({ own: null });
  const first = mergeChoice(null, { strategy: "stale,forget", apply: "default", budget: "64k" }, blank);
  assert.deepEqual(first, { strategy: ["stale", "forget"], budget_tokens: 64000 });
  const opened = ownValues({ own: first });
  assert.deepEqual(mergeChoice(first, { ...opened, apply: "turn_end" }, opened),
                   { strategy: ["stale", "forget"], budget_tokens: 64000, apply: "turn_end" });
  assert.deepEqual(mergeChoice(first, { ...opened, strategy: "default" }, opened), { budget_tokens: 64000 });
  assert.equal(mergeChoice(first, { strategy: "default", apply: "default", budget: "" }, opened), null);
  assert.deepEqual(mergeChoice(null, { strategy: "none", apply: "default", budget: "off" }, blank), { strategy: [], budget_tokens: 0 });
  assert.equal(mergeChoice(null, blank, blank), null);
  assert.throws(() => mergeChoice(null, { ...blank, budget: "12" }, blank), { message: BUDGET_ERROR });
});

test("the choice goes to POST /api/sessions as /llm-context words; none goes as nothing", () => {
  assert.deepEqual(choiceWords({ strategy: ["forget", "stale"], apply: "turn_end", budget_tokens: 64000 }),
                   { strategy: "stale,forget", apply: "turn_end", budget: "64000" });
  assert.deepEqual(choiceWords({ strategy: [], budget_tokens: 0 }), { strategy: "none", budget: "off" });
  assert.equal(choiceWords(null), undefined);
  assert.equal(choiceWords({}), undefined);
});

test("a budget reads as chi reads one: tokens, k, off; out of range is none", () => {
  assert.equal(parseBudget("64k"), 64000);
  assert.equal(parseBudget(" 64_000 "), 64000);
  assert.equal(parseBudget("OFF"), 0);
  assert.equal(parseBudget("0"), 0);
  assert.equal(parseBudget("00"), 0);
  assert.equal(parseBudget("0k"), 0);
  assert.equal(parseBudget("3999"), null);
  assert.equal(parseBudget("lots"), null);
});
