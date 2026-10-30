// The start page's ⚙ panel (start_settings.js): its rows' segments, the
// override chips' words, and the panel in happy-dom (picks, the Apply and
// budget disclosure, the review view, hidden rows). start_page.test.js
// covers it wired to the page's choices.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  contextSegments, contextWords, createStartSettings, overrides, panelTemplate, settingsLabel, thinkingSegments,
} from "../../../lib/samagotchi/web/public/start_settings.js";
import { markupOf } from "./dom_shim.js";

const THINKING = { level: "high", source: "models: qwen", own: null };
const LLM_CONTEXT = { strategy: "none", apply: "payoff", budget_tokens: null, own: null };

const labels = (segments) => segments.map((s) => `${s.label}${s.pressed ? "*" : ""}`);

test("the Thinking row: the model's level first, the choice pressed; none without the model's thinking", () => {
  assert.deepEqual(labels(thinkingSegments(THINKING, null)), ["default (high)*", "off", "low", "medium", "high"]);
  assert.deepEqual(labels(thinkingSegments(THINKING, "low")), ["default (high)", "off", "low*", "medium", "high"]);
  assert.equal(thinkingSegments({ level: "default" }, null)[0].label, "default"); // the model has none of its own
  assert.equal(thinkingSegments(null, "low"), null);
  assert.equal(thinkingSegments({ level: null }, null), null);
});

test("the Context row: the model's strategy first, stale + forget experimental in its tooltip; an unknown choice added", () => {
  const segs = contextSegments(LLM_CONTEXT, null);
  assert.deepEqual(labels(segs), ["default (none)*", "none", "stale", "stale + forget"]);
  assert.equal(segs[3].title, "stale + forget (experimental)");
  assert.deepEqual(labels(contextSegments(LLM_CONTEXT, { strategy: [] })), ["default (none)", "none*", "stale", "stale + forget"]);
  assert.deepEqual(labels(contextSegments(LLM_CONTEXT, { strategy: ["forget", "stale"] })).at(3), "stale + forget*");
  assert.deepEqual(labels(contextSegments(LLM_CONTEXT, { strategy: ["forget"] })).at(-1), "forget*");
  assert.deepEqual(labels(contextSegments(LLM_CONTEXT, { budget_tokens: 64000 }))[0], "default (none)*");
  assert.equal(contextSegments(null, { strategy: [] }), null);
});

test("override chips: only what is set, sent anyway when the model has no row for it; ⚙'s label lists them", () => {
  const none = overrides({ thinkingSummary: THINKING, llmContextSummary: LLM_CONTEXT });
  assert.deepEqual(none, { thinking: null, llmContext: null, review: null });
  assert.deepEqual(settingsLabel(none), { set: false, label: "Session settings" });
  const all = overrides({ thinking: "high", llmContext: { strategy: ["stale"], budget_tokens: 64000 }, review: ["docs/a.md", "b.md"],
                          thinkingSummary: THINKING, llmContextSummary: LLM_CONTEXT });
  assert.equal(all.thinking.text, "think high");
  assert.match(all.thinking.title, /^Thinking: high for the new session \(the model's: high\)/);
  assert.equal(all.llmContext.text, "ctx stale · budget 64000");
  assert.equal(all.review.text, "review: a.md +1");
  assert.deepEqual(settingsLabel(all), { set: true, label: "Session settings: think high, ctx stale · budget 64000, review: a.md +1" });
  const orphan = overrides({ thinking: "low", llmContext: { apply: "turn_end" } });
  assert.match(orphan.thinking.title, /the picked model has no thinking setting; it is sent anyway/);
  assert.equal(orphan.llmContext.text, "ctx apply turn_end");
  assert.match(orphan.llmContext.title, /it is sent anyway/);
  assert.equal(contextWords({ budget_tokens: 0 }), "budget off");
  assert.equal(contextWords(null), null);
});

test("the panel: rows hidden without the model's values, a choice left over said and clearable, the note", () => {
  const markup = markupOf(panelTemplate({ thinking: { summary: null, choice: "high" }, llmContext: { summary: null, choice: null },
                                          review: [] }));
  assert.doesNotMatch(markup, /ss-row/);
  assert.match(markup, /Thinking high: the picked model has no thinking setting; it is sent anyway\./);
  assert.match(markup, /data-act="think-clear"/);
  assert.match(markup, /Review files…/);
  assert.doesNotMatch(markup, /ss-rule/); // no rows above the review: no rule
  assert.match(markup, /For this new session only\./);
  const noReview = markupOf(panelTemplate({ thinking: { summary: THINKING, choice: null },
                                            llmContext: { summary: LLM_CONTEXT, choice: null } }));
  assert.match(noReview, /role="group"/);
  assert.doesNotMatch(noReview, /Review files/);
});

// A panel in happy-dom over plain state, ⚙ on the body.
function panel(t, { thinkingSummary = THINKING, llmSummary = LLM_CONTEXT, choice = {} } = {}) {
  const button = document.createElement("button");
  button.id = "gearTest";
  document.body.append(button);
  const state = { thinking: null, llmContext: null, review: [], ...choice };
  const ctl = createStartSettings({
    el: button, button,
    thinking: { summary: () => thinkingSummary, choice: () => state.thinking, choose: (next) => { state.thinking = next; } },
    llmContext: { summary: () => llmSummary, choice: () => state.llmContext, choose: (next) => { state.llmContext = next; } },
    review: { choice: () => state.review, choose: (next) => { state.review = next; } },
    win: { innerWidth: 1000, innerHeight: 800 },
  });
  const pop = [...document.querySelectorAll("#startSettingsPopover")].pop();
  t.after(() => { button.remove(); pop.remove(); });
  const act = (name) => pop.querySelector(`[data-act="${name}"]`).click();
  const submit = (sel) => pop.querySelector(sel).dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  return { button, ctl, pop, state, act, submit };
}

test("a pick applies at once and keeps the panel open; default unsets it", (t) => {
  const p = panel(t);
  p.button.click();
  assert.equal(p.pop.getAttribute("aria-label"), "Session settings");
  assert.ok(document.activeElement === p.pop.querySelector("[aria-pressed=true]")); // the first row's pressed segment
  p.act("think:low");
  assert.equal(p.state.thinking, "low");
  assert.equal(p.pop.hidden, false);
  assert.equal(p.pop.querySelector('[data-act="think:low"]').getAttribute("aria-pressed"), "true");
  p.act("think:default");
  assert.equal(p.state.thinking, null);
  p.act("ctx:stale");
  assert.deepEqual(p.state.llmContext, { strategy: ["stale"] });
  p.act("ctx:none");
  assert.deepEqual(p.state.llmContext, { strategy: [] });
  p.act("ctx:default");
  assert.equal(p.state.llmContext, null);
});

test("Apply and budget: a disclosure, open when the choice has them; a bad budget's error, an edit clears it", (t) => {
  const p = panel(t);
  p.button.click();
  assert.equal(p.pop.querySelector(".ss-ctx-form"), null);
  p.act("ctx-more");
  const form = p.pop.querySelector(".ss-ctx-form");
  assert.equal(p.pop.querySelector('[data-act="ctx-more"]').getAttribute("aria-expanded"), "true");
  assert.equal(form.querySelector("option[selected]").textContent, "default (payoff)");
  form.elements.budget.value = "12";
  p.submit(".ss-ctx-form");
  const error = () => p.pop.querySelector(".ss-ctx-form .ctx-pop-error");
  assert.equal(error().hidden, false);
  assert.match(error().textContent, /A budget is a number of tokens/);
  assert.equal(p.state.llmContext, null);
  form.elements.budget.value = "64k";
  form.elements.budget.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(error().hidden, true);
  p.submit(".ss-ctx-form");
  assert.deepEqual(p.state.llmContext, { budget_tokens: 64000 });
  // A strategy pick keeps the budget.
  p.act("ctx:stale");
  assert.deepEqual(p.state.llmContext, { budget_tokens: 64000, strategy: ["stale"] });
  p.act("close");
  p.button.click();
  assert.ok(p.pop.querySelector(".ss-ctx-form")); // open: the choice has a budget
  assert.equal(p.pop.querySelector(".ss-ctx-form").elements.budget.value, "64000");
});

test("the review view: ‹ back, an open quote's error, Set returns with the files, No review clears them", (t) => {
  const p = panel(t);
  p.button.click();
  p.act("review");
  assert.ok(document.activeElement === p.pop.querySelector("textarea"));
  p.act("back");
  assert.equal(p.pop.querySelector("textarea"), null);
  p.act("review");
  p.pop.querySelector("textarea").value = '"docs/my plan';
  p.submit("form.rs-form");
  assert.equal(p.pop.querySelector(".ctx-pop-error").textContent, 'A quote isn\'t closed: "docs/my plan');
  assert.deepEqual(p.state.review, []);
  p.pop.querySelector("textarea").value = '"docs/my plan.md"';
  p.submit("form.rs-form");
  assert.deepEqual(p.state.review, ["docs/my plan.md"]);
  assert.match(p.pop.querySelector(".ss-review-set").textContent, /Review: my plan\.md/);
  assert.ok(document.activeElement === p.pop.querySelector('[data-act="review"]')); // Edit
  p.act("review");
  assert.equal(p.pop.querySelector("textarea").value, '"docs/my plan.md"');
  p.act("clear"); // No review
  assert.deepEqual(p.state.review, []);
  assert.ok(p.pop.querySelector(".ss-row"));
  p.state.review = ["a.md"];
  p.ctl.refresh();
  p.act("review-clear");
  assert.deepEqual(p.state.review, []);
});

test("a closed panel opens on the main view again; refuse opens the review view with the message", (t) => {
  const p = panel(t, { choice: { review: ["x.md"] } });
  p.ctl.open("review");
  assert.ok(p.pop.querySelector("textarea"));
  assert.equal(p.button.getAttribute("aria-expanded"), "true");
  p.act("close");
  assert.equal(p.button.getAttribute("aria-expanded"), "false");
  p.button.click();
  assert.equal(p.button.getAttribute("aria-expanded"), "true");
  assert.equal(p.pop.querySelector("textarea"), null);
  p.ctl.refuse("x.md: no such file");
  assert.equal(p.pop.querySelector(".ctx-pop-error").textContent, "x.md: no such file");
  assert.equal(p.pop.querySelector("textarea").getAttribute("aria-invalid"), "true");
});
