// The session bar's LLM context chip: the strategy the next turn runs under
// ("llm ctx stale,forget"; "· session" when the session set its own), and a
// popover that sets the session's own strategy, apply rule and budget by
// running /llm-context in its worker (the command's reply shows in the
// conversation, like a typed one). The values and where each came from are
// the session's llm_context (LLMContextStrategy::Explained#summary: the
// worker's snapshot, a command_ran, or the server's own reading of the
// session file).
//
// The start page's new session sets its strategy in the ⚙ panel instead
// (start_settings.js): mergeChoice and choiceWords are its, a choice in the
// session file's shape sent as POST /api/sessions' llm_context words.

import { createChipPopover } from "./chip_popover.js";
import { html, nothing, render } from "./vendor/lit-html.js";

const STRATEGIES = [
  { value: "none", label: "none" },
  { value: "stale", label: "stale" },
  { value: "stale,forget", label: "stale + forget (experimental)" },
];
export const APPLIES = ["payoff", "next_request", "turn_end"];
export const SESSION = "session";

const DEFAULT = "default";
const LAYER_ORDER = ["stale", "forget"];

// Layers as one value, in chi's order (stale before forget); unknown ones after.
export function strategyValue(layers) {
  if (!layers.length) return "none";
  const rank = (name) => { const at = LAYER_ORDER.indexOf(name); return at < 0 ? LAYER_ORDER.length : at; };
  return [...layers].sort((a, b) => rank(a) - rank(b)).join(",");
}

// The session's own values as the form shows them: a strategy value, an
// apply rule and a budget word ("64000", "off"); "default" / "" for unset.
export function ownValues(summary) {
  const own = summary?.own || {};
  const strategy = Array.isArray(own.strategy) ? strategyValue(own.strategy) : DEFAULT;
  const budget = typeof own.budget_tokens === "number" ? (own.budget_tokens > 0 ? String(own.budget_tokens) : "off") : "";
  return { strategy, apply: own.apply || DEFAULT, budget };
}

// The chip: its text, tooltip and whether the session set its own; null
// without a summary (an older worker).
export function chipModel(summary) {
  if (!summary || !summary.strategy) return null;
  const own = summary.strategy_source === "session" || !!summary.own;
  const budget = summary.budget_tokens ? `${summary.budget_tokens} tokens` : "off";
  const title = `LLM context strategy: ${summary.strategy} (${summary.strategy_where}); apply ${summary.apply} ` +
    `(${summary.apply_where}); budget ${budget} (${summary.budget_where}). Click to change it for this session.`;
  return { text: `llm ctx ${summary.strategy}${own ? ` · ${SESSION}` : ""}`, title, own };
}

// The session bar's chip (a lit-html template; info_bar.js), nothing
// without a summary.
export function chipTemplate(summary) {
  const chip = chipModel(summary);
  if (!chip) return nothing;
  return html`<button type="button" class=${`model llmctx-chip${chip.own ? " own" : ""}`} title=${chip.title} aria-haspopup="dialog">${chip.text}</button>`;
}

// The /llm-context line for the form's values. With +initial+ (the values
// the form opened with) only the fields the user changed go, so a value the
// form can't show is never unset by a Set; null when nothing changed.
// Without it every field goes, "default" for one left to the model, and all
// of them default is a reset. With --yes: the form states what a change
// costs, so a Set is the choice (no confirm step), as level_chip.js's.
export function commandLine({ strategy = DEFAULT, apply = DEFAULT, budget = "" } = {}, initial = null) {
  const words = { strategy, apply, budget: String(budget).trim() || DEFAULT };
  const was = initial && { strategy: initial.strategy, apply: initial.apply, budget: String(initial.budget).trim() || DEFAULT };
  const fields = Object.keys(words).filter((field) => !was || words[field] !== was[field]);
  if (!fields.length) return null;
  if (!was && fields.every((field) => words[field] === DEFAULT)) return "/llm-context reset --yes";
  return `/llm-context ${fields.map((field) => `${field} ${words[field]}`).join(" ")} --yes`;
}

// A budget as typed ("64000", "64k", "off", "0") in tokens, 0 for off;
// null when it isn't one or is out of chi's range (LLMContextOverride).
export function parseBudget(text) {
  const word = String(text).trim().toLowerCase();
  if (word === "off" || word === "0") return 0;
  const match = /^(\d[\d_]*)(k)?$/.exec(word);
  if (!match) return null;
  const tokens = Number(match[1].replace(/_/g, "")) * (match[2] ? 1000 : 1);
  if (tokens === 0) return 0; // "00", "0k": off, as chi reads them
  return tokens >= 4000 && tokens <= 10_000_000 ? tokens : null;
}

// The new session's choice (start_settings.js) after a pick or a Set:
// +choice+ with the fields the user changed (vs +initial+, the values
// before) applied, a field set back to default dropped; null when nothing
// is left. Throws on a budget that isn't one.
export function mergeChoice(choice, { strategy = DEFAULT, apply = DEFAULT, budget = "" } = {}, initial = null) {
  const next = { ...(choice || {}) };
  const words = { strategy, apply, budget: String(budget).trim() || DEFAULT };
  const was = initial && { strategy: initial.strategy, apply: initial.apply, budget: String(initial.budget).trim() || DEFAULT };
  const key = { strategy: "strategy", apply: "apply", budget: "budget_tokens" };
  for (const field of Object.keys(words)) {
    if (was && words[field] === was[field]) continue;
    const word = words[field];
    if (word === DEFAULT) { delete next[key[field]]; continue; }
    if (field === "strategy") next.strategy = word === "none" ? [] : word.split(/[\s,|]+/).filter(Boolean);
    else if (field === "apply") next.apply = word;
    else {
      const tokens = parseBudget(word);
      if (tokens === null) throw new Error("A budget is a number of tokens from 4000 (4k) to 10000000, or off.");
      next.budget_tokens = tokens;
    }
  }
  return Object.keys(next).length ? next : null;
}

// The choice as POST /api/sessions' llm_context words it ({strategy:
// "stale,forget"|"none", apply, budget: "64000"|"off"}, the set fields);
// undefined without one, so the request has none.
export function choiceWords(choice) {
  if (!choice) return undefined;
  const words = {};
  if (Array.isArray(choice.strategy)) words.strategy = strategyValue(choice.strategy);
  if (choice.apply) words.apply = choice.apply;
  if (typeof choice.budget_tokens === "number") words.budget = choice.budget_tokens > 0 ? String(choice.budget_tokens) : "off";
  return Object.keys(words).length ? words : undefined;
}

// The strategy list, with the session's own value when it isn't one of them
// (forget alone, a newer chi's layer).
function strategyOptions(chosen) {
  if (chosen === DEFAULT || STRATEGIES.some((s) => s.value === chosen)) return STRATEGIES;
  return [...STRATEGIES, { value: chosen, label: chosen }];
}

const option = (value, label) => html`<option value=${value}>${label}</option>`;

// The popover's form: the values now (each with its source), and the
// session's own to change.
export function nowText(summary) {
  const budget = summary.budget_tokens ? `${summary.budget_tokens} tokens` : "off";
  return `Now: ${summary.strategy} (${summary.strategy_where}) · apply ${summary.apply} (${summary.apply_where}) · ` +
    `budget ${budget} (${summary.budget_where})`;
}

// The popover's form (a lit-html template). +now+ is the summary its "Now:"
// line reads (refresh passes a newer one, the rest stays as the form opened,
// so lit leaves what the user typed alone); +error+ a failed Set's message.
// The selects take their value as a property (.value), set after their
// options: +unset+ draws the options alone, the first pass renderForm makes.
export function formTemplate(summary, { running = false, now = summary, error = null, unset = false } = {}) {
  const own = ownValues(summary);
  const follow = (field) => (summary[`${field}_source`] === "session" ? "follow the model" : `follow the model (${summary[field]})`);
  const when = "From the next turn's start. Turning forget on or off re-reads the whole prompt once.";
  const chosen = (value) => (unset ? nothing : value);
  return html`<form class="llmctx-form"><div class="ctx-pop-head"><strong>LLM context</strong
    ><span class="ctx-pop-kind">this session</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class="ctx-pop-meta llmctx-now">${nowText(now)}</div
    ><label class="llmctx-field"><span>Strategy</span><span class="select-wrap"><select name="strategy" .value=${chosen(own.strategy)}>${
      option(DEFAULT, follow("strategy"))}${strategyOptions(own.strategy).map((s) => option(s.value, s.label))}</select></span></label
    ><label class="llmctx-field"><span>Apply</span><span class="select-wrap"><select name="apply" .value=${chosen(own.apply)}>${
      option(DEFAULT, follow("apply"))}${APPLIES.map((a) => option(a, a))}</select></span></label
    ><label class="llmctx-field"><span>Budget</span><input name="budget" type="text" inputmode="numeric" autocomplete="off"
      placeholder="follow the model (64000, 64k or off)" .value=${own.budget}></label
    ><div class="ctx-pop-error llmctx-error" ?hidden=${!error}>${error || ""}</div
    ><div class="ctx-pop-meta">${when}${running ? " A turn is running: it applies after this turn." : ""}</div
    ><div class="ctx-pop-actions"><button type="button" class="ctx-pop-detach" data-act="reset">follow the model</button
    ><button type="submit" class="llmctx-set">Set</button></div></form>`;
}

// Draws the form into +target+ (formTemplate's options). A first draw (no
// form there yet) makes two passes, the options and then the selects'
// values: lit sets an element's own bindings before its children, so a
// select's .value would land before its options exist. A later draw is
// one pass, and lit writes only what changed since the last (the "Now:"
// line, the error), never a value the user changed.
export function renderForm(target, summary, opts = {}) {
  if (!target.firstElementChild) render(formTemplate(summary, { ...opts, unset: true }), target);
  render(formTemplate(summary, opts), target);
}

// The chip's popover (chip_popover.js' shell). el: where the chip is drawn
// (#infoText, info_bar.js: clicks are delegated); summary(): the open
// session's llm_context; session(): the open session's id; running(): a
// turn runs; run(line): sends the command. id and anchor: the popover's id
// and the chip's selector.
export function createLlmContextControl({ el, summary, session = () => null, running = () => false, run,
                                          id = "llmContextPopover", anchor = ".llmctx-chip",
                                          doc = document, win = window }) {
  // The values the form opened with.
  let initial = null;
  // What the open form was drawn from: the summary, the form's options and
  // the summary its "Now:" line reads.
  let shown = null;
  const draw = (changes = {}) => {
    shown = { ...shown, ...changes };
    renderForm(shell.pop, shown.data, { ...shown.opts, now: shown.now, error: shown.error });
  };

  // A refresh (a newer summary): an open form keeps what the user typed;
  // only its "Now:" line follows (the same template again: lit writes that
  // line alone).
  function show(data, opening) {
    if (!opening) return draw({ now: data });
    initial = ownValues(data);
    shown = { data, opts: { running: running() } };
    draw({ now: data, error: null });
  }

  function submit(form) {
    const values = { strategy: form.elements.strategy.value, apply: form.elements.apply.value,
                     budget: form.elements.budget.value };
    const line = commandLine(values, initial);
    shell.close();
    if (line) run(line);
  }

  function act(name) {
    if (name !== "reset") return;
    shell.close();
    run(commandLine());
  }

  const shell = createChipPopover({
    id, className: "ctx-popover llmctx-popover", width: 360, el, anchor, summary, session, show,
    onClose: () => { initial = null; shown = null; }, onSubmit: submit, onAct: act, doc, win,
  });
  // An edit makes an error the last Set showed stale.
  const clearError = () => {
    if (shown?.error) draw({ error: null });
  };
  shell.pop.addEventListener("input", clearError);
  shell.pop.addEventListener("change", clearError);

  return { close: shell.close, refresh: shell.refresh, get open() { return shell.isOpen(); } };
}
