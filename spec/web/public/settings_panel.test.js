// The settings panel's shared rows (settings_panel.js): the segments, the
// rows a caller passes, the disclosure and the review line.
// start_settings.test.js covers the start page's panel drawn through it.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  contextMoreTemplate, contextSegments, contextWords, segmentsTemplate, sentAnywayTemplate, settingsPanelTemplate,
  thinkingSegments,
} from "../../../lib/samagotchi/web/public/settings_panel.js";
import { markupOf } from "./dom_shim.js";

const LLM_CONTEXT = { strategy: "stale", apply: "payoff", budget_tokens: 64000, own: null };
const labels = (segments) => segments.map((s) => `${s.label}${s.pressed ? "*" : ""}`);

test("the Thinking and Context segments: follow the model first, the choice pressed; null without the summary", () => {
  assert.deepEqual(labels(thinkingSegments({ level: "low" }, "high")), ["default (low)", "off", "low", "medium", "high*"]);
  assert.deepEqual(labels(contextSegments(LLM_CONTEXT, null)), ["default (stale)*", "none", "stale", "stale + forget"]);
  assert.deepEqual(labels(contextSegments(LLM_CONTEXT, { strategy: ["stale"] })), ["default (stale)", "none", "stale*", "stale + forget"]);
  assert.equal(thinkingSegments(null, null), null);
  assert.equal(contextSegments({ strategy: null }, null), null);
  assert.equal(contextWords({ strategy: ["stale"], apply: "turn_end" }), "stale · apply turn_end");
});

test("a row of segments: its label names the group, each segment its act and pressed state", () => {
  const markup = markupOf(segmentsTemplate("rh", "Reasoning history", [{ value: "all", label: "all", pressed: true },
    { value: "drop", label: "drop", title: "Drop it", pressed: false }], "reasoning"));
  assert.match(markup, /<span class="sset-label" id="sset-rh-label">Reasoning history<\/span>/);
  assert.match(markup, /role="group" aria-labelledby="sset-rh-label"/);
  assert.match(markup, /data-act="reasoning:all" aria-pressed="true"/);
  assert.match(markup, /data-act="reasoning:drop" aria-pressed="false"\s+title="Drop it">drop/);
});

test("the disclosure's fields: the model's apply and budget as the defaults, the choice's own values, the error", () => {
  const markup = markupOf(contextMoreTemplate(LLM_CONTEXT, { apply: "turn_end" }, "Budget: a number"));
  assert.match(markup, /<option value="default">default \(payoff\)<\/option>/);
  assert.match(markup, /<option value="turn_end" selected="">turn_end<\/option>/);
  assert.match(markup, /placeholder="default \(64000\): 64000, 64k or off"/);
  assert.match(markup, /<div class="ctx-pop-error" role="alert">Budget: a number<\/div>/);
  assert.match(markupOf(sentAnywayTemplate("Gone.", "x-clear")), /Gone\.\s+<button type="button" class="sset-link" data-act="x-clear">Clear<\/button>/);
});

test("the panel: heading and kind, the rows in the caller's order (null skipped), the disclosure, review line and note", () => {
  const ctx = contextSegments(LLM_CONTEXT, null);
  const rows = [
    { name: "rh", label: "Reasoning history", segments: [{ value: "all", label: "all", pressed: true }], act: "reasoning" },
    null,
    { name: "ctx", label: "Context", segments: ctx, act: "ctx", more: { open: false, summary: LLM_CONTEXT, choice: null, error: null } },
    { anyway: "Thinking low: sent anyway.", act: "think-clear" },
  ];
  const closed = markupOf(settingsPanelTemplate({ heading: "Session settings", kind: "this session", rows, note: "Soon." }));
  assert.match(closed, /<strong>Session settings<\/strong><span class="ctx-pop-kind">this session<\/span>/);
  assert.ok(closed.indexOf("sset-rh-label") < closed.indexOf("sset-ctx-label"));
  assert.ok(closed.indexOf("sset-ctx-label") < closed.indexOf("Thinking low: sent anyway."));
  assert.match(closed, /data-act="ctx-more" aria-expanded="false">Apply and budget ▸/);
  assert.doesNotMatch(closed, /sset-ctx-form|sset-review|Review files/);
  assert.match(closed, /<div class="ctx-pop-meta">Soon\.<\/div>$/);
  rows[2].more.open = true;
  const open = markupOf(settingsPanelTemplate({ heading: "New session", rows, review: [], note: "N." }));
  assert.doesNotMatch(open, /ctx-pop-kind/);
  assert.match(open, /aria-expanded="true">Apply and budget ▾/);
  assert.match(open, /<form class="sset-ctx-form">/);
  assert.match(open, /<hr class="sset-rule"><div class="sset-review">/);
  assert.match(open, /Review files…/);
  const reviewOnly = markupOf(settingsPanelTemplate({ heading: "New session", rows: [null], review: ["a.md"], note: "N." }));
  assert.doesNotMatch(reviewOnly, /sset-rule/);
  assert.match(reviewOnly, /Review: a\.md<\/span>/);
});
