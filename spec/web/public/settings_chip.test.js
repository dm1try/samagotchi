// The session bar's ⚙ chip and panel (settings_chip.js): the chip's words,
// the panel's rows over a session's summaries, and what a pick runs (one
// field alone, D2 of the session-bar-trims plan).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import {
  actLine, chipModel, chipTemplate, createSettingsControl, moreLine, noteText, panelTemplate,
} from "../../../lib/samagotchi/web/public/settings_chip.js";
import { BUDGET_ERROR } from "../../../lib/samagotchi/web/public/llm_context_chip.js";
import { markupOf } from "./dom_shim.js";

const THINK_MODEL = { level: "high", source: "models: qwen", own: null };
const THINK_OWN = { level: "low", source: "session", own: "low" };
const RH_MODEL = { level: "turn", source: "hosts.splash", own: null };
const RH_OWN = { level: "all", source: "session", own: "all" };
const CTX_MODEL = {
  strategy: "none", strategy_source: "config", strategy_where: "llm_context.strategy",
  apply: "payoff", apply_source: "config", apply_where: "llm_context.apply",
  budget_tokens: null, budget_source: "config", budget_where: "llm_context.budget_tokens", own: null,
};
// The session set its own apply rule only: the strategy still follows.
const CTX_OWN_APPLY = { ...CTX_MODEL, apply: "turn_end", apply_source: "session", apply_where: "the session",
                        own: { apply: "turn_end" } };
const CTX_OWN = {
  ...CTX_MODEL, strategy: "stale", strategy_source: "session", strategy_where: "the session",
  budget_tokens: 64000, budget_source: "session", budget_where: "the session",
  own: { strategy: ["stale"], budget_tokens: 64000 },
};
const labels = (markup, group) => [...markup.matchAll(new RegExp(`data-act="${group}:[^"]*" aria-pressed="(true|false)"[^>]*>([^<]*)<`, "g"))]
  .map(([, pressed, label]) => `${label}${pressed === "true" ? "*" : ""}`);

test("the chip: ⚙ alone while the session follows the model, its tooltip each value and where it comes from", () => {
  const chip = chipModel({ thinking: THINK_MODEL, reasoningHistory: RH_MODEL, llmContext: CTX_MODEL });
  assert.equal(chip.text, "");
  assert.equal(chip.own, false);
  assert.equal(chip.label, "Session settings");
  assert.equal(chip.title, "Thinking: high (models: qwen). Reasoning history: turn (hosts.splash). " +
    "LLM context: none (llm_context.strategy); apply payoff (llm_context.apply); budget off (llm_context.budget_tokens). " +
    "Click to change them for this session.");
  const markup = markupOf(chipTemplate({ thinking: THINK_MODEL, reasoningHistory: null, llmContext: CTX_MODEL }));
  assert.match(markup, /class="model settings-chip" title="Thinking: high/);
  assert.match(markup, /aria-label="Session settings"><span class="chip-icon sc-gear" aria-hidden="true">⚙<\/span><\/button>$/);
  assert.match(markup, /data-settings-chip/);
});

test("the chip names only what the session set, in the start page's words; class own", () => {
  const chip = chipModel({ thinking: THINK_OWN, reasoningHistory: RH_OWN, llmContext: CTX_OWN });
  assert.equal(chip.text, "think low · reasoning all · ctx stale · budget 64000");
  assert.equal(chip.own, true);
  assert.equal(chip.label, "Session settings: think low, reasoning all, ctx stale · budget 64000");
  assert.match(chip.title, /^Thinking: low \(this session\)\. Reasoning history: all \(this session\)\. LLM context: stale \(the session\)/);
  assert.equal(chipModel({ thinking: THINK_MODEL, llmContext: CTX_OWN_APPLY }).text, "ctx apply turn_end");
  const markup = markupOf(chipTemplate({ thinking: THINK_OWN, reasoningHistory: null, llmContext: CTX_MODEL }));
  assert.match(markup, /class="model settings-chip own"/);
  assert.match(markup, /<span class="chip-icon sc-gear" aria-hidden="true">⚙<\/span><span class="sc-own"> think low<\/span>/);
});

test("no chip without any summary (an older worker)", () => {
  assert.equal(chipModel({ thinking: null, reasoningHistory: null, llmContext: null }), null);
  assert.equal(markupOf(chipTemplate({ thinking: null, reasoningHistory: null, llmContext: null })), "");
  assert.equal(markupOf(chipTemplate(null)), "");
});

test("the panel: Thinking, Reasoning history (a chat host's) and Context; the default names the model's value only while the session follows it", () => {
  const follows = markupOf(panelTemplate({ thinking: THINK_MODEL, reasoningHistory: RH_MODEL, llmContext: CTX_MODEL }));
  assert.match(follows, /<strong>Session settings<\/strong><span class="ctx-pop-kind">this session<\/span>/);
  assert.deepEqual(labels(follows, "think"), ["default (high)*", "off", "low", "medium", "high"]);
  assert.deepEqual(labels(follows, "reasoning"), ["default (turn)*", "drop", "turn", "all"]);
  assert.match(follows, /id="sset-rh-label">Reasoning<\/span>/);
  assert.deepEqual(labels(follows, "ctx"), ["default (none)*", "none", "stale", "stale + forget"]);
  assert.doesNotMatch(follows, /Review files|sset-review/);
  const own = markupOf(panelTemplate({ thinking: THINK_OWN, reasoningHistory: null, llmContext: CTX_OWN, more: true }));
  assert.deepEqual(labels(own, "think"), ["default", "off", "low*", "medium", "high"]);
  assert.doesNotMatch(own, /sset-rh-label/);
  assert.deepEqual(labels(own, "ctx"), ["default", "none", "stale*", "stale + forget"]);
  // The disclosure: the session's own budget in the field, its default plain; apply still the model's.
  assert.match(own, /<option value="default" selected="">default \(payoff\)<\/option>/);
  assert.match(own, /placeholder="default: 64000, 64k or off"/);
  const ownApply = markupOf(panelTemplate({ thinking: null, llmContext: CTX_OWN_APPLY, more: true }));
  assert.match(ownApply, /<option value="default">default<\/option>/);
  assert.match(ownApply, /<option value="turn_end" selected="">turn_end<\/option>/);
  assert.deepEqual(labels(ownApply, "ctx"), ["default (none)*", "none", "stale", "stale + forget"]);
});

test("the note: from the next turn's start, after the running turn while one runs, each drawn row's cost", () => {
  assert.equal(noteText({ thinking: true, llmContext: true }),
    "From the next turn's start. A thinking change: on Gemma the whole prompt is read again; a hosted API reads the " +
    "whole conversation again. Turning forget on or off re-reads the whole prompt once.");
  assert.match(noteText({ thinking: true, running: true }), /^From the next turn's start\. A turn is running: it applies after this turn\. A thinking/);
  assert.match(noteText({ reasoningHistory: true }), /to or from all makes the server read the conversation again\.$/);
});

test("a pick runs its field alone: a strategy tap keeps the session's own apply and budget", () => {
  const summaries = { thinking: THINK_OWN, reasoningHistory: RH_MODEL, llmContext: CTX_OWN_APPLY };
  assert.equal(actLine("ctx:stale", summaries), "/llm-context strategy stale --yes");
  assert.equal(actLine("ctx:stale,forget", { llmContext: CTX_OWN }), "/llm-context strategy stale,forget --yes");
  assert.equal(actLine("ctx:stale", { llmContext: CTX_OWN }), null);
  assert.equal(actLine("think:high", summaries), "/thinking high --yes");
  assert.equal(actLine("think:low", summaries), null);
  assert.equal(actLine("think:default", summaries), "/thinking default --yes");
  assert.equal(actLine("reasoning:all", summaries), "/reasoning-history all --yes");
  assert.equal(actLine("reasoning:default", summaries), null);
});

test("the Context row's default is the reset, only when the session has any of its own", () => {
  assert.equal(actLine("ctx:default", { llmContext: CTX_OWN_APPLY }), "/llm-context reset --yes");
  assert.equal(actLine("ctx:default", { llmContext: CTX_OWN }), "/llm-context reset --yes");
  assert.equal(actLine("ctx:default", { llmContext: CTX_MODEL }), null);
});

test("the disclosure's Set sends the apply rule or budget that changed alone; a budget chi wouldn't take is an error", () => {
  assert.deepEqual(moreLine({ apply: "turn_end", budget: "64000" }, CTX_OWN), { line: "/llm-context apply turn_end --yes" });
  assert.deepEqual(moreLine({ apply: "turn_end", budget: "32k" }, CTX_OWN_APPLY), { line: "/llm-context budget 32k --yes" });
  assert.deepEqual(moreLine({ apply: "default", budget: "" }, CTX_OWN_APPLY), { line: "/llm-context apply default --yes" });
  assert.deepEqual(moreLine({ apply: "default", budget: "64000" }, CTX_OWN), { line: null });
  assert.deepEqual(moreLine({ apply: "default", budget: "12" }, CTX_OWN), { error: BUDGET_ERROR });
});

// A control on the shim's document: the chip inside +el+, a stub window
// for the popover's place; +state+ is what summaries() reads (a refresh
// after a reply is a new state and refresh()).
function control(state, opts = {}) {
  const el = document.createElement("div");
  document.body.append(el);
  const drawChip = () => render(chipTemplate(state.summaries), el);
  drawChip();
  const ran = [];
  const ctl = createSettingsControl({ el, summaries: () => state.summaries, session: () => state.id || "s1",
                                      running: () => !!state.running, run: (line) => ran.push(line),
                                      win: { innerWidth: 1000, innerHeight: 800 }, ...opts });
  const pop = document.getElementById("settingsPopover");
  const chip = () => el.querySelector("[data-settings-chip]");
  const tap = (act) => pop.querySelector(`[data-act="${act}"]`).click();
  const pressed = (group) => pop.querySelector(`[aria-labelledby="sset-${group}-label"] [aria-pressed=true]`)?.textContent;
  return { ctl, el, pop, chip, ran, tap, pressed, drawChip, done: () => { el.remove(); pop.remove(); } };
}

test("a tap runs its line at once and the panel stays open; the pressed segment follows the reply, not the tap", () => {
  const state = { summaries: { thinking: THINK_MODEL, reasoningHistory: null, llmContext: CTX_OWN_APPLY } };
  const c = control(state);
  c.chip().click();
  assert.equal(c.ctl.open, true);
  assert.equal(c.pressed("think"), "default (high)");
  c.tap("ctx:stale");
  c.tap("think:low");
  assert.deepEqual(c.ran, ["/llm-context strategy stale --yes", "/thinking low --yes"]);
  assert.equal(c.ctl.open, true);
  assert.equal(c.pressed("think"), "default (high)");
  // The replies land (command_ran): the store's summaries change and the panel redraws.
  state.summaries = { ...state.summaries, thinking: THINK_OWN,
                      llmContext: { ...CTX_OWN_APPLY, strategy: "stale", strategy_source: "session",
                                    own: { strategy: ["stale"], apply: "turn_end" } } };
  c.ctl.refresh();
  assert.equal(c.pressed("think"), "low");
  assert.equal(c.pressed("ctx"), "stale");
  // The next tap reads the newer own values: the apply rule still isn't sent.
  c.tap("ctx:none");
  assert.equal(c.ran.at(-1), "/llm-context strategy none --yes");
  c.tap("think:low");
  assert.equal(c.ran.length, 3);
  c.done();
});

test("the disclosure opens with an own apply or budget; its Set runs the changed field; a bad budget is said under it", () => {
  const state = { summaries: { thinking: null, reasoningHistory: null, llmContext: CTX_OWN }, running: true };
  const c = control(state);
  c.chip().click();
  assert.match(c.pop.textContent, /A turn is running: it applies after this turn\./);
  const form = c.pop.querySelector(".sset-ctx-form");
  assert.ok(form);
  assert.equal(form.elements.budget.value, "64000");
  form.elements.apply.value = "turn_end";
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  assert.deepEqual(c.ran, ["/llm-context apply turn_end --yes"]);
  form.elements.apply.value = "default";
  form.elements.budget.value = "12";
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  assert.equal(c.ran.length, 1);
  assert.equal(c.pop.querySelector(".ctx-pop-error").textContent, BUDGET_ERROR);
  form.elements.budget.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(c.pop.querySelector(".ctx-pop-error").hidden, true);
  c.tap("ctx-more");
  assert.equal(c.pop.querySelector(".sset-ctx-form"), null);
  c.done();
});

test("another session's refresh closes the panel; no summaries opens nothing", () => {
  const state = { summaries: { thinking: THINK_MODEL, reasoningHistory: null, llmContext: null } };
  const c = control(state);
  c.chip().click();
  assert.equal(c.ctl.open, true);
  state.id = "s2";
  c.ctl.refresh();
  assert.equal(c.ctl.open, false);
  state.summaries = { thinking: null, reasoningHistory: null, llmContext: null };
  c.el.innerHTML = '<button data-settings-chip>⚙</button>';
  c.chip().click();
  assert.equal(c.ctl.open, false);
  c.done();
});
