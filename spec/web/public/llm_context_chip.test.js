import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  chipModel, chipTemplate, choiceWords, commandLine, createLlmContextControl, mergeChoice, NEW_SESSION, ownValues, parseBudget,
  renderForm, strategyValue, withChoice,
} from "../../../lib/samagotchi/web/public/llm_context_chip.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

// A template's markup (lit's marker comments dropped).
const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};

// The form as the popover draws it: its fields' values, the options'
// values and labels, and the lines' text.
const formOf = (summary, opts) => {
  const div = document.createElement("div");
  renderForm(div, summary, opts);
  const form = div.querySelector("form");
  const field = (name) => form.elements[name];
  const options = (name) => [...field(name).options].map((o) => [o.value, o.textContent]);
  const text = (sel) => form.querySelector(sel).textContent;
  return { form, field, options, text, all: form.textContent };
};

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
  assert.equal(markupOf(chipTemplate(null)), "");
  assert.match(markupOf(chipTemplate(own)), /class="model llmctx-chip own"/);
});

test("the form starts from the session's own values, default for the unset ones", () => {
  assert.deepEqual(ownValues(fromModel), { strategy: "default", apply: "default", budget: "" });
  assert.deepEqual(ownValues(own), { strategy: "stale,forget", apply: "default", budget: "64000" });
  assert.deepEqual(ownValues({ own: { strategy: [], budget_tokens: 0 } }), { strategy: "none", apply: "default", budget: "off" });

  const f = formOf(own);
  assert.equal(f.field("strategy").value, "stale,forget");
  assert.equal(f.field("apply").value, "default");
  assert.deepEqual(f.options("apply")[0], ["default", "follow the model (payoff)"]);
  assert.equal(f.field("budget").value, "64000");
  assert.match(f.text(".llmctx-now"), /^Now: stale,forget \(the session\)/);
  assert.equal(f.form.querySelector("[disabled]"), null);
  assert.equal(f.form.querySelector(".llmctx-error").hidden, true);
  assert.doesNotMatch(f.all, /A turn is running/);
  // Mid-turn a Set is queued for after the turn (it applies at the next turn's start anyway).
  const mid = formOf(own, { running: true });
  assert.equal(mid.form.querySelector("[disabled]"), null);
  assert.match(mid.all, /A turn is running: it applies after this turn\./);
});

test("a strategy the list has no option for (forget alone, forget,stale) is shown as the session's own, in chi's order", () => {
  assert.equal(strategyValue(["forget", "stale"]), "stale,forget");
  assert.equal(strategyValue([]), "none");
  const forgetOnly = { ...own, strategy: "forget", own: { strategy: ["forget"] } };
  assert.deepEqual(ownValues(forgetOnly), { strategy: "forget", apply: "default", budget: "" });
  const f = formOf(forgetOnly);
  assert.equal(f.field("strategy").value, "forget");
  assert.deepEqual(f.options("strategy").map(([value]) => value), ["default", "none", "stale", "stale,forget", "forget"]);
  assert.deepEqual(f.options("strategy")[0], ["default", "follow the model"]);
  assert.equal(formOf({ ...own, own: { strategy: ["forget", "stale"] } }).field("strategy").value, "stale,forget");
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

// The start page's chip (kind "new session"): the picked model's values, and a
// choice kept for the next create only.
test("the new session's chip shows the model's values, and a choice marked · new session", () => {
  assert.equal(chipModel(withChoice(fromModel, null), { kind: NEW_SESSION }).text, "llm ctx stale");
  assert.equal(chipModel(fromModel, { kind: NEW_SESSION }).own, false);
  assert.match(chipModel(fromModel, { kind: NEW_SESSION }).title, /Click to change it for the new session\.$/);

  const chosen = withChoice(fromModel, { strategy: ["forget", "stale"], budget_tokens: 0 });
  const chip = chipModel(chosen, { kind: NEW_SESSION });
  assert.equal(chip.text, "llm ctx stale,forget · new session");
  assert.equal(chip.own, true);
  assert.match(chip.title, /stale,forget \(the new session\); apply payoff \(llm_context.apply\); budget off \(the new session\)/);
  assert.equal(chipModel(withChoice(fromModel, { apply: "turn_end" }), { kind: NEW_SESSION }).text, "llm ctx stale · new session");
});

test("the new session's form is titled for it, shows the model's values as Now and the choice in its fields", () => {
  const f = formOf(fromModel, { kind: NEW_SESSION, choice: { strategy: [], apply: "turn_end", budget_tokens: 64000 } });
  assert.equal(f.text(".ctx-pop-kind"), "new session");
  assert.match(f.text(".llmctx-now"), /^Now: stale \(models: qwen\)/);
  assert.equal(f.field("strategy").value, "none");
  assert.equal(f.field("apply").value, "turn_end");
  assert.equal(f.field("budget").value, "64000");
  assert.deepEqual(f.options("strategy")[0], ["default", "follow the model (stale)"]);
  assert.match(f.all, /not remembered/);
  assert.equal(formOf(fromModel, { kind: NEW_SESSION }).field("strategy").value, "default");
  assert.equal(formOf(own).text(".ctx-pop-kind"), "this session");
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

// A control on the shim's document: the chip inside +el+, a stub window
// for the popover's place.
function control(opts) {
  const el = document.createElement("div");
  el.innerHTML = '<button class="llmctx-chip">llm ctx</button>';
  document.body.append(el);
  const ran = [];
  const win = { innerWidth: 1000, innerHeight: 800 };
  const ctl = createLlmContextControl({ el, run: (line) => ran.push(line), win, ...opts });
  const pop = document.getElementById(opts.id || "llmContextPopover");
  const chip = el.querySelector(".llmctx-chip");
  const submit = () => pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  const field = (name) => pop.querySelector("form").elements[name];
  const type = (name, value) => {
    field(name).value = value;
    field(name).dispatchEvent(new window.Event("input", { bubbles: true }));
  };
  const error = () => pop.querySelector(".llmctx-error");
  return { ctl, pop, chip, ran, submit, field, type, error, done: () => { el.remove(); pop.remove(); } };
}

test("a click on the chip opens the form at the session's values; a Set runs only the changed fields", () => {
  const c = control({ summary: () => own, session: () => "s1" });
  c.chip.click();
  assert.equal(c.ctl.open, true);
  assert.equal(c.field("strategy").value, "stale,forget");
  assert.equal(c.field("budget").value, "64000");
  c.type("apply", "turn_end");
  c.submit();
  assert.deepEqual(c.ran, ["/llm-context apply turn_end --yes"]);
  assert.equal(c.ctl.open, false);
  assert.equal(c.pop.querySelector("form"), null);
  c.chip.click();
  c.pop.querySelector("[data-act=reset]").click();
  assert.deepEqual(c.ran, ["/llm-context apply turn_end --yes", "/llm-context reset --yes"]);
  c.done();
});

test("a refresh keeps what the user typed and picked; the Now: line follows; another session closes it", () => {
  let data = fromModel;
  let id = "s1";
  const c = control({ summary: () => data, session: () => id });
  c.chip.click();
  const now = c.pop.querySelector(".llmctx-now");
  c.type("budget", "32k");
  c.type("strategy", "stale,forget");
  data = own;
  c.ctl.refresh();
  assert.ok(c.pop.querySelector(".llmctx-now") === now, "the Now: line is the same node");
  assert.match(now.textContent, /^Now: stale,forget \(the session\)/);
  assert.equal(c.field("budget").value, "32k");
  assert.equal(c.field("strategy").value, "stale,forget");
  c.submit();
  assert.deepEqual(c.ran, ["/llm-context strategy stale,forget budget 32k --yes"]);
  c.chip.click();
  id = "s2";
  c.ctl.refresh();
  assert.equal(c.ctl.open, false);
  c.done();
});

test("the new session's Set shows a bad budget's error, an edit clears it, a refresh keeps it", () => {
  const picks = [];
  const c = control({ summary: () => fromModel, kind: NEW_SESSION, choice: () => null, choose: (next) => picks.push(next),
                      id: "llmContextNewPopover", anchor: ".llmctx-chip" });
  c.chip.click();
  c.field("budget").value = "12";
  c.submit();
  assert.equal(c.ctl.open, true);
  assert.equal(c.error().hidden, false);
  assert.match(c.error().textContent, /A budget is a number of tokens/);
  c.ctl.refresh();
  assert.equal(c.error().hidden, false);
  assert.equal(c.field("budget").value, "12");
  c.type("budget", "64k");
  assert.equal(c.error().hidden, true);
  assert.equal(c.error().textContent, "");
  c.submit();
  assert.deepEqual(picks, [{ budget_tokens: 64000 }]);
  c.done();
});
