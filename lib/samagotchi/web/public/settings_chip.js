// The session bar's ⚙ chip and its panel: the open session's thinking,
// reasoning history and LLM context in one place, as the start page's ⚙
// panel has them for a new session (settings_panel.js draws both). The chip
// reads "⚙" alone while the session follows the model for all three, else
// "⚙" and the session's own in the start page's words ("⚙ think low · ctx
// stale"; class own, the accent). A pick in the panel runs that row's
// command with --yes in the session's worker at once (one reply line in the
// conversation, like a typed /thinking low) and the panel stays open; the
// pressed segment follows the session's summary when the reply's command_ran
// lands, never the tap. The summaries are the session's thinking,
// reasoning_history and llm_context (SettingExplained#summary,
// LLMContextStrategy::Explained#summary: the worker's snapshot, a
// command_ran, or the server's own reading of the session file).
//
// A new module: the page's modules are cached at unversioned URLs, and a
// new export of an old module would leave a cached copy without it.

import { createChipPopover, SHEET_TALL } from "./chip_popover.js";
import { DEFAULT, commandLine as levelLine, segments } from "./level_chip.js";
import { BUDGET_ERROR, commandLine as contextLine, ownValues, parseBudget } from "./llm_context_chip.js";
import { CONFIG as REASONING } from "./reasoning_history_chip.js";
import { contextSegments, contextWords, settingsPanelTemplate } from "./settings_panel.js";
import { CONFIG as THINKING } from "./thinking_chip.js";
import { html, nothing, render } from "./vendor/lit-html.js";

export const PANEL_LABEL = "Session settings";
export const NOTE = "From the next turn's start.";
export const RUNNING_NOTE = "A turn is running: it applies after this turn.";
const CONTEXT_COST = "Turning forget on or off re-reads the whole prompt once.";

// A level's own value ("low"), null when it follows the model.
const levelOwn = (summary) => summary?.own || null;

// The context's own values in a few words ("stale · budget 64000"), null
// when the session has none.
const contextOwn = (summary) => (summary?.own ? contextWords(summary.own) : null);

function levelTitle(cfg, summary) {
  return `${cfg.name}: ${summary.level} (${summary.own ? "this session" : summary.source || "the model's own"})`;
}

function contextTitle(summary) {
  const budget = summary.budget_tokens ? `${summary.budget_tokens} tokens` : "off";
  return `LLM context: ${summary.strategy} (${summary.strategy_where}); apply ${summary.apply} (${summary.apply_where}); ` +
    `budget ${budget} (${summary.budget_where})`;
}

// The chip for +summaries+ ({thinking, reasoningHistory, llmContext}, each
// a summary or null): {text (the own values past ⚙, "" for none), own,
// title (each value and where it comes from), label (the accessible name:
// the panel and what is set, settingsLabel's shape)}; null without any
// summary (an older worker: no chip).
export function chipModel({ thinking = null, reasoningHistory = null, llmContext = null } = {}) {
  const think = thinking?.level ? thinking : null;
  const rh = reasoningHistory?.level ? reasoningHistory : null;
  const ctx = llmContext?.strategy ? llmContext : null;
  if (!think && !rh && !ctx) return null;
  const set = [
    levelOwn(think) && `${THINKING.prefix} ${levelOwn(think)}`,
    levelOwn(rh) && `${REASONING.prefix} ${levelOwn(rh)}`,
    contextOwn(ctx) && `ctx ${contextOwn(ctx)}`,
  ].filter(Boolean);
  const lines = [think && levelTitle(THINKING, think), rh && levelTitle(REASONING, rh), ctx && contextTitle(ctx)].filter(Boolean);
  return {
    text: set.join(" · "),
    own: set.length > 0,
    title: `${lines.join(". ")}. Click to change them for this session.`,
    label: set.length ? `${PANEL_LABEL}: ${set.join(", ")}` : PANEL_LABEL,
  };
}

// The session bar's chip (a lit-html template; info_bar.js), nothing
// without a summary. ⚙ is drawn as the start page's settings icon (the
// glyph stays the text); the own values are a span of their own: a phone
// shows ⚙ with a dot instead (index.html's CSS).
export function chipTemplate(summaries) {
  const chip = summaries && chipModel(summaries);
  if (!chip) return nothing;
  return html`<button type="button" class=${`model settings-chip${chip.own ? " own" : ""}`} title=${chip.title}
    aria-label=${chip.label} aria-haspopup="dialog" data-settings-chip><span class="chip-icon sc-gear" aria-hidden="true">⚙</span>${
    chip.text ? html`<span class="sc-own"> ${chip.text}</span>` : nothing}</button>`;
}

// The panel's note: when a change applies (after the running turn, while
// one runs) and what each drawn row's change costs.
export function noteText({ thinking, reasoningHistory, llmContext, running = false }) {
  return [NOTE, running ? RUNNING_NOTE : null, thinking ? THINKING.cost : null, reasoningHistory ? REASONING.cost : null,
          llmContext ? CONTEXT_COST : null].filter(Boolean).join(" ");
}

// The panel (settings_panel.js settingsPanelTemplate) over the session's
// summaries: the Thinking row, the Reasoning history row (a chat host's
// only), the Context row with its Apply and budget disclosure; each row's
// pressed segment the session's own. +more+: the disclosure open; +error+:
// its Set's.
export function panelTemplate({ thinking = null, reasoningHistory = null, llmContext = null, running = false,
                                more = false, error = null }) {
  const think = segments(THINKING, thinking, levelOwn(thinking));
  const rh = segments(REASONING, reasoningHistory, levelOwn(reasoningHistory));
  const ctx = contextSegments(llmContext, llmContext?.own || null);
  return settingsPanelTemplate({
    heading: PANEL_LABEL,
    kind: "this session",
    rows: [
      think ? { name: "think", label: THINKING.name, segments: think, act: "think" } : null,
      // "Reasoning", the chip's word: "Reasoning history" wraps in the label's column.
      rh ? { name: "rh", label: "Reasoning", segments: rh, act: "reasoning" } : null,
      ctx ? { name: "ctx", label: "Context", segments: ctx, act: "ctx",
              more: { open: more, summary: llmContext, choice: llmContext.own || null, error } } : null,
    ],
    note: noteText({ thinking: think, reasoningHistory: rh, llmContext: ctx, running }),
  });
}

// What a pick (+act+, a segment's data-act: "think:low", "reasoning:all",
// "ctx:stale", "ctx:default") runs for +summaries+: the line, or null (the
// segment pressed already). One field alone (D2): a strategy tap sends the
// strategy only, the session's own apply and budget stay; the Context
// row's default is the reset (strategy, apply and budget follow the model
// again), only when the session has any of its own.
export function actLine(act, { thinking = null, reasoningHistory = null, llmContext = null } = {}) {
  const [what, value] = act.split(/:(.*)/s);
  if (what === "think") return levelLine(THINKING, value, levelOwn(thinking) || DEFAULT);
  if (what === "reasoning") return levelLine(REASONING, value, levelOwn(reasoningHistory) || DEFAULT);
  if (what !== "ctx") return null;
  if (value === DEFAULT) return llmContext?.own ? contextLine() : null;
  const initial = ownValues(llmContext);
  return contextLine({ ...initial, strategy: value }, initial);
}

// The disclosure's Set: the apply rule and the budget as typed, against the
// session's own; only the field that changed goes. {line} (null: nothing
// changed) or {error} (a budget chi wouldn't take).
export function moreLine({ apply, budget }, llmContext) {
  const typed = String(budget ?? "").trim();
  if (typed && parseBudget(typed) === null) return { error: BUDGET_ERROR };
  const initial = ownValues(llmContext);
  return { line: contextLine({ ...initial, apply, budget: typed }, initial) };
}

// The chip's panel on chip_popover.js' shell (a bottom sheet on a phone).
// el: where the chip is drawn (#infoText, info_bar.js: clicks are
// delegated); summaries(): the open session's {thinking, reasoningHistory,
// llmContext} (null: no session); session(): its id; running(): a turn
// runs; run(line): sends the command.
// @return {close, refresh, open}
export function createSettingsControl({ el, summaries, session = () => null, running = () => false, run,
                                        id = "settingsPopover", anchor = "[data-settings-chip]",
                                        doc = document, win = window }) {
  // The summaries the open panel is drawn from (each refresh's newer ones),
  // the disclosure and its Set's error.
  let shown = null;
  let more = false;
  let error = null;

  function draw() {
    render(panelTemplate({ ...shown, running: running(), more, error }), shell.pop);
    shell.replace();
  }

  function show(data, opening) {
    shown = data;
    if (opening) {
      const own = data.llmContext?.own;
      more = !!(own?.apply || typeof own?.budget_tokens === "number");
      error = null;
    }
    draw();
  }

  function act(name) {
    if (name === "ctx-more") {
      more = !more;
      return draw();
    }
    const line = actLine(name, shown);
    if (line) run(line);
  }

  function submit(form) {
    if (!form.classList.contains("sset-ctx-form")) return;
    const result = moreLine({ apply: form.elements.apply.value, budget: form.elements.budget.value }, shown.llmContext);
    error = result.error || null;
    draw();
    if (result.line) run(result.line);
  }

  // Focus inside on open (the popover sits at the end of <body>): the
  // pressed segment of the first row.
  function focusInside() {
    shell.pop.querySelector(".sset-seg [aria-pressed=true]")?.focus();
  }

  const present = () => {
    const data = summaries();
    return data && chipModel(data) ? data : null;
  };
  const shell = createChipPopover({
    id, className: "ctx-popover start-settings session-settings", width: 440, el, anchor, summary: present, session,
    show, sheet: true, sheetShare: SHEET_TALL, modal: true, label: PANEL_LABEL, onOpen: focusInside,
    onClose: () => { shown = null; error = null; }, onSubmit: submit, onAct: act, doc, win,
  });
  // An edit makes the disclosure Set's error stale.
  shell.pop.addEventListener("input", (e) => {
    if (error && e.target.closest(".sset-ctx-form")) {
      error = null;
      draw();
    }
  });

  return { close: shell.close, refresh: shell.refresh, get open() { return shell.isOpen(); } };
}
