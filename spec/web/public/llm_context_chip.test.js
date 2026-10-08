import test from "node:test";
import assert from "node:assert/strict";
import {
  chipModel, chipHtml, choiceWords, commandLine, formHtml, mergeChoice, NEW_CHAT, ownValues, parseBudget, popoverPlace,
  strategyValue, withChoice,
} from "../../../lib/samagotchi/web/public/llm_context_chip.js";

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
  // Mid-turn a Set is queued for after the turn (it applies at the next turn's start anyway).
  assert.doesNotMatch(formHtml(own, esc, { running: true }), /disabled/);
  assert.match(formHtml(own, esc, { running: true }), /A turn is running: it applies after this turn\./);
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

// The start page's chip (kind "new chat"): the picked model's values, and a
// choice kept for the next create only.
test("the new chat's chip shows the model's values, and a choice marked · new chat", () => {
  assert.equal(chipModel(withChoice(fromModel, null), { kind: NEW_CHAT }).text, "llm ctx stale");
  assert.equal(chipModel(fromModel, { kind: NEW_CHAT }).own, false);
  assert.match(chipModel(fromModel, { kind: NEW_CHAT }).title, /Click to change it for the new chat\.$/);

  const chosen = withChoice(fromModel, { strategy: ["forget", "stale"], budget_tokens: 0 });
  const chip = chipModel(chosen, { kind: NEW_CHAT });
  assert.equal(chip.text, "llm ctx stale,forget · new chat");
  assert.equal(chip.own, true);
  assert.match(chip.title, /stale,forget \(the new chat\); apply payoff \(llm_context.apply\); budget off \(the new chat\)/);
  assert.equal(chipModel(withChoice(fromModel, { apply: "turn_end" }), { kind: NEW_CHAT }).text, "llm ctx stale · new chat");
});

test("the new chat's form is titled for it, shows the model's values as Now and the choice in its fields", () => {
  const html = formHtml(fromModel, esc, { kind: NEW_CHAT, choice: { strategy: [], apply: "turn_end", budget_tokens: 64000 } });
  assert.match(html, /<span class="ctx-pop-kind">new chat<\/span>/);
  assert.match(html, /Now: stale \(models: qwen\)/);
  assert.match(html, /<option value="none" selected>/);
  assert.match(html, /<option value="turn_end" selected>/);
  assert.match(html, /name="budget"[^>]*value="64000"/);
  assert.match(html, /<option value="default">follow the model \(stale\)<\/option>/);
  assert.match(html, /not remembered/);
  assert.match(formHtml(fromModel, esc, { kind: NEW_CHAT }), /<select name="strategy"><option value="default" selected>/);
  assert.match(formHtml(own, esc), /<span class="ctx-pop-kind">this session<\/span>/);
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
  assert.throws(() => mergeChoice(null, { ...blank, budget: "12" }, blank), /A budget is a number of tokens/);
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

test("the popover opens above the chip, below it when the room above is short, capped to the room it has", () => {
  const win = { width: 343, innerWidth: 375, innerHeight: 560 };
  // Room above: opens upward, its bottom 8 px over the chip.
  assert.deepEqual(popoverPlace({ left: 130, top: 470, bottom: 494 }, { ...win, height: 300 }), { left: 16, bottom: 98 });
  // A chip near the top: below it.
  assert.deepEqual(popoverPlace({ left: 20, top: 60, bottom: 84 }, { ...win, height: 300 }), { left: 16, top: 92 });
  // Neither side fits: the roomier one, capped (it scrolls), never above the window's top.
  assert.deepEqual(popoverPlace({ left: 20, top: 300, bottom: 324 }, { ...win, height: 400 }), { left: 16, bottom: 268, maxHeight: 276 });
});
