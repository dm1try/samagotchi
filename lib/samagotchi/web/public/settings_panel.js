// The settings panel's rows, drawn by the start page's ⚙ panel
// (start_settings.js) over a new session's choices and by the session bar's
// (settings_chip.js) over the open session's own: rows of segments
// (Thinking, Context), the Context row's Apply and budget disclosure, a
// line for a choice whose row is hidden, the review files' line. The caller
// passes the rows it draws (settingsPanelTemplate's +rows+) and applies the
// picks itself; the segments' data-act ("think:low", "ctx:stale",
// "ctx-more") is the same for every caller.

import { APPLIES, choiceWords, ownValues, strategyValue } from "./llm_context_chip.js";
import { DEFAULT, followSegment, segments } from "./level_chip.js";
import { reviewChipModel } from "./review_start.js";
import { CONFIG as THINKING } from "./thinking_chip.js";
import { html, nothing } from "./vendor/lit-html.js";

export { DEFAULT };

const STRATEGIES = [
  { value: "none", label: "none" },
  { value: "stale", label: "stale" },
  { value: "stale,forget", label: "stale + forget", title: "stale + forget (experimental)" },
];

// The Thinking row's segments (level_chip.js segments over thinking_chip.js'
// levels): the model's own level first ("default (high)"; "default" while
// the session has its own), then the levels;
// the pressed one is the choice. null without the model's thinking (the row
// is hidden).
export function thinkingSegments(summary, choice) {
  return segments(THINKING, summary, choice);
}

// Whether the summary's +field+ (strategy, apply, budget) is the session's
// own: the value in force is then not the model's, so a default label
// doesn't name it.
const ownField = (summary, field) => summary?.[`${field}_source`] === "session";

// The Context row's segments over the strategies (a choice that isn't one
// of them, a newer chi's layer, is added); null without the model's
// llm_context (the row is hidden).
export function contextSegments(summary, choice) {
  if (!summary?.strategy) return null;
  const pressed = Array.isArray(choice?.strategy) ? strategyValue(choice.strategy) : DEFAULT;
  const list = STRATEGIES.some((s) => s.value === pressed) || pressed === DEFAULT ? STRATEGIES
    : [...STRATEGIES, { value: pressed, label: pressed }];
  return [followSegment(summary.strategy, ownField(summary, "strategy")), ...list]
    .map((s) => ({ ...s, pressed: s.value === pressed }));
}

// The context choice in a few words ("stale · budget 64000"), or null.
export function contextWords(choice) {
  const words = choiceWords(choice);
  if (!words) return null;
  return [words.strategy, words.apply && `apply ${words.apply}`, words.budget && `budget ${words.budget}`]
    .filter(Boolean).join(" · ");
}

export const segmentsTemplate = (name, label, segs, act) => html`<div class="sset-row"><span class="sset-label"
  id=${`sset-${name}-label`}>${label}</span><div class="sset-seg" role="group" aria-labelledby=${`sset-${name}-label`}>${
  segs.map((s) => html`<button type="button" data-act=${`${act}:${s.value}`} aria-pressed=${s.pressed ? "true" : "false"}
    title=${s.title || nothing}>${s.label}</button>`)}</div></div>`;

const option = (value, label, chosen) => html`<option value=${value} ?selected=${value === chosen}>${label}</option>`;

// The disclosure's fields: the apply rule and the budget, with their own
// Set (a typed budget needs a commit) and mergeChoice's error under them.
// Each default names the model's value, unless the session set its own
// (the summary's value is the session's then).
export function contextMoreTemplate(summary, choice, error) {
  const own = ownValues({ own: choice });
  const budget = summary.budget_tokens ? String(summary.budget_tokens) : "off";
  const apply = ownField(summary, "apply") ? DEFAULT : `${DEFAULT} (${summary.apply})`;
  const budgetDefault = ownField(summary, "budget") ? DEFAULT : `${DEFAULT} (${budget})`;
  return html`<form class="sset-ctx-form"><label class="llmctx-field"><span>Apply</span><span class="select-wrap"><select
    name="apply">${option(DEFAULT, apply, own.apply)}${APPLIES.map((a) => option(a, a, own.apply))}</select
    ></span></label><label class="llmctx-field"><span>Budget</span><input name="budget" type="text" inputmode="numeric"
    autocomplete="off" placeholder=${`${budgetDefault}: 64000, 64k or off`} .value=${own.budget}></label
    ><div class="ctx-pop-error" role="alert" ?hidden=${!error}>${error || ""}</div
    ><div class="ctx-pop-actions"><button type="submit" class="llmctx-set">Set</button></div></form>`;
}

// A choice whose row is hidden (the picked model has no values for it).
export const sentAnywayTemplate = (text, act) => html`<div class="sset-anyway ctx-pop-meta">${text}
  <button type="button" class="sset-link" data-act=${act}>Clear</button></div>`;

// One of the panel's rows, null drawing nothing:
//   {name, label, segments, act}: a row of segments (segmentsTemplate);
//     with +more+ ({open, summary, choice, error}) the Apply and budget
//     disclosure under it, its fields while open (contextMoreTemplate)
//   {anyway, act}: the line for a choice whose row is hidden, its Clear
//     button's data-act (sentAnywayTemplate)
function rowTemplate(row) {
  if (!row) return nothing;
  if (row.anyway) return sentAnywayTemplate(row.anyway, row.act);
  const { more } = row;
  return html`${segmentsTemplate(row.name, row.label, row.segments, row.act)}${more ? html`<div class="sset-ctx-more"
    ><button type="button" class="sset-link" data-act="ctx-more" aria-expanded=${more.open ? "true" : "false"}>Apply and budget ${
      more.open ? "▾" : "▸"}</button></div>${more.open ? contextMoreTemplate(more.summary, more.choice, more.error) : nothing}`
    : nothing}`;
}

// The review files' line: the files set (Edit, Remove), else Review files….
function reviewTemplate(review, ruled) {
  const chip = review.length ? reviewChipModel(review) : null;
  return html`${ruled ? html`<hr class="sset-rule">` : nothing}<div class="sset-review">${chip
    ? html`<span class="sset-review-set" title=${chip.title}>Review: ${chip.text.replace(/^review: /, "")}</span
      ><button type="button" class="sset-link" data-act="review">Edit</button><button type="button" class="sset-link"
      data-act="review-clear">Remove</button>`
    : html`<button type="button" class="sset-link" data-act="review" title=${reviewChipModel([]).title}>Review files…</button>`}</div>`;
}

// The panel: its heading (+kind+ beside it, or none) and close button, the
// +rows+ (rowTemplate's), the review files' line when +review+ is a list
// (null: no review line; a rule above it when a row of segments is drawn),
// and the +note+.
export function settingsPanelTemplate({ heading, kind = null, rows = [], review = null, note }) {
  const segmented = rows.some((row) => row?.segments);
  return html`<div class="ctx-pop-head"><strong>${heading}</strong>${kind ? html`<span class="ctx-pop-kind">${kind}</span>` : nothing
    }<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    >${rows.map(rowTemplate)}${review ? reviewTemplate(review, segmented) : nothing}<div class="ctx-pop-meta">${note}</div>`;
}
