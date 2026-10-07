import test from "node:test";
import assert from "node:assert/strict";
import { chipModel, chipHtml, commandLine, formHtml, ownValues, strategyValue } from "../../../lib/samagotchi/web/public/llm_context_chip.js";

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

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

test("the chip names the strategy, and the session when it set its own", () => {
  assert.equal(chipModel(fromModel).text, "llm ctx stale");
  assert.equal(chipModel(fromModel).own, false);
  assert.match(chipModel(fromModel).title, /stale \(models: qwen\); apply payoff \(llm_context.apply\); budget off/);
  assert.equal(chipModel(own).text, "llm ctx stale,forget · session");
  assert.equal(chipModel(null), null);
  assert.equal(chipHtml(null, esc), "");
  assert.match(chipHtml(own, esc), /class="model llmctx-chip own"/);
});

test("the form starts from the session's own values, default for the unset ones", () => {
  assert.deepEqual(ownValues(fromModel), { strategy: "default", apply: "default", budget: "" });
  assert.deepEqual(ownValues(own), { strategy: "stale,forget", apply: "default", budget: "64000" });
  assert.deepEqual(ownValues({ own: { strategy: [], budget_tokens: 0 } }), { strategy: "none", apply: "default", budget: "off" });

  const html = formHtml(own, esc);
  assert.match(html, /<option value="stale,forget" selected>/);
  assert.match(html, /<option value="default" selected>follow the model \(payoff\)<\/option>/);
  assert.match(html, /name="budget"[^>]*value="64000"/);
  assert.match(html, /Now: stale,forget \(the session\)/);
  assert.doesNotMatch(html, /disabled/);
  assert.match(formHtml(own, esc, { running: true }), /class="llmctx-set" disabled/);
});

test("a strategy the list has no option for (forget alone, forget,stale) is shown as the session's own, in chi's order", () => {
  assert.equal(strategyValue(["forget", "stale"]), "stale,forget");
  assert.equal(strategyValue([]), "none");
  const forgetOnly = { ...own, strategy: "forget", own: { strategy: ["forget"] } };
  assert.deepEqual(ownValues(forgetOnly), { strategy: "forget", apply: "default", budget: "" });
  assert.match(formHtml(forgetOnly, esc), /<option value="forget" selected>forget<\/option>/);
  assert.match(formHtml(forgetOnly, esc), /<select name="strategy"><option value="default">follow/);
  assert.match(formHtml({ ...own, own: { strategy: ["forget", "stale"] } }, esc), /<option value="stale,forget" selected>/);
});

test("Set sends only the fields the user changed, so a value it left alone is never unset", () => {
  const initial = ownValues({ own: { strategy: ["forget"], budget_tokens: 64000 } });
  assert.equal(commandLine({ strategy: "forget", apply: "turn_end", budget: "64000" }, initial), "/llm-context apply turn_end");
  assert.equal(commandLine({ strategy: "forget", apply: "default", budget: "" }, initial), "/llm-context budget default");
  assert.equal(commandLine({ ...initial }, initial), null);
});

test("the command sets every field, default for the ones left to the model; all default is a reset", () => {
  assert.equal(commandLine({ strategy: "stale,forget", apply: "turn_end", budget: " 64k " }),
               "/llm-context strategy stale,forget apply turn_end budget 64k");
  assert.equal(commandLine({ strategy: "none", apply: "default", budget: "" }),
               "/llm-context strategy none apply default budget default");
  assert.equal(commandLine({}), "/llm-context reset");
});
