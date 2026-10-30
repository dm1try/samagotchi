// The start page's ⚙ panel: the new session's rarely used settings in one
// place (thinking, LLM context, review files), each a choice for the next
// create only (start_page.js keeps them; never remembered). A pick applies
// at once and the panel stays open; a typed budget has its own Set. Rows
// the picked model has no values for are hidden, but a choice already made
// is still sent: the panel says so and offers to clear it. The review files
// are a view of their own (‹ back to the settings).
//
// Beside ⚙ on the row, override chips name what is set (overrides(): "think
// high", "ctx stale", "review: README.md"); on a phone ⚙ carries a dot
// instead (settingsLabel()).

import { createChipPopover } from "./chip_popover.js";
import { APPLIES, choiceWords, mergeChoice, ownValues, strategyValue } from "./llm_context_chip.js";
import { readSubjects, reviewChipModel, reviewFormTemplate } from "./review_start.js";
import { LEVELS } from "./thinking_chip.js";
import { html, nothing, render } from "./vendor/lit-html.js";

export const DEFAULT = "default";
export const NOTE = "For this new session only.";
export const PANEL_LABEL = "Session settings";
const NO_THINKING = "the picked model has no thinking setting; it is sent anyway";
const NO_LLM_CONTEXT = "the picked model has no LLM context values; it is sent anyway";

const STRATEGIES = [
  { value: "none", label: "none" },
  { value: "stale", label: "stale" },
  { value: "stale,forget", label: "stale + forget", title: "stale + forget (experimental)" },
];

// The first segment: follow the model, its value in brackets ("default
// (high)"; a model with no level of its own, "default" alone).
const followSegment = (value) => ({ value: DEFAULT, label: value === DEFAULT ? DEFAULT : `${DEFAULT} (${value})`,
                                    title: `Follow the model (${value})` });

// The Thinking row's segments: the model's own level first ("default
// (high)"), then the levels; the pressed one is the choice. null without
// the model's thinking (the row is hidden).
export function thinkingSegments(summary, choice) {
  if (!summary?.level) return null;
  const pressed = choice || DEFAULT;
  return [followSegment(summary.level),
    ...LEVELS.map((level) => ({ value: level, label: level }))].map((s) => ({ ...s, pressed: s.value === pressed }));
}

// The Context row's segments over the strategies (a choice that isn't one
// of them, a newer chi's layer, is added); null without the model's
// llm_context (the row is hidden).
export function contextSegments(summary, choice) {
  if (!summary?.strategy) return null;
  const pressed = Array.isArray(choice?.strategy) ? strategyValue(choice.strategy) : DEFAULT;
  const list = STRATEGIES.some((s) => s.value === pressed) || pressed === DEFAULT ? STRATEGIES
    : [...STRATEGIES, { value: pressed, label: pressed }];
  return [followSegment(summary.strategy), ...list].map((s) => ({ ...s, pressed: s.value === pressed }));
}

// The context choice in a few words ("stale · budget 64000"), or null.
export function contextWords(choice) {
  const words = choiceWords(choice);
  if (!words) return null;
  return [words.strategy, words.apply && `apply ${words.apply}`, words.budget && `budget ${words.budget}`]
    .filter(Boolean).join(" · ");
}

// The row's override chips: what is set for the new session, each
// {text, title} or null. A choice the picked model shows no row for (its
// summary is null) stays, its title saying it is sent anyway.
export function overrides({ thinking = null, llmContext = null, review = [], thinkingSummary = null,
                            llmContextSummary = null } = {}) {
  const ctx = contextWords(llmContext);
  return {
    thinking: thinking ? {
      text: `think ${thinking}`,
      title: thinkingSummary
        ? `Thinking: ${thinking} for the new session (the model's: ${thinkingSummary.level}). Click to change it.`
        : `Thinking: ${thinking} for the new session: ${NO_THINKING}. Click to change it.`,
    } : null,
    llmContext: ctx ? {
      text: `ctx ${ctx}`,
      title: llmContextSummary
        ? `LLM context: ${ctx} for the new session (the model's: ${llmContextSummary.strategy}). Click to change it.`
        : `LLM context: ${ctx} for the new session: ${NO_LLM_CONTEXT}. Click to change it.`,
    } : null,
    review: review?.length ? reviewChipModel(review) : null,
  };
}

// ⚙'s state: whether anything is set (its dot on a phone) and its tooltip
// and accessible name, which list what is.
export function settingsLabel(over) {
  const set = [over.thinking, over.llmContext, over.review].filter(Boolean);
  return { set: set.length > 0, label: set.length ? `${PANEL_LABEL}: ${set.map((o) => o.text).join(", ")}` : PANEL_LABEL };
}

const segmentsTemplate = (name, label, segments, act) => html`<div class="sset-row"><span class="sset-label"
  id=${`sset-${name}-label`}>${label}</span><div class="sset-seg" role="group" aria-labelledby=${`sset-${name}-label`}>${
  segments.map((s) => html`<button type="button" data-act=${`${act}:${s.value}`} aria-pressed=${s.pressed ? "true" : "false"}
    title=${s.title || nothing}>${s.label}</button>`)}</div></div>`;

const option = (value, label, chosen) => html`<option value=${value} ?selected=${value === chosen}>${label}</option>`;

// The disclosure's fields: the apply rule and the budget, with their own
// Set (a typed budget needs a commit) and mergeChoice's error under them.
function contextMoreTemplate(summary, choice, error) {
  const own = ownValues({ own: choice });
  const budget = summary.budget_tokens ? String(summary.budget_tokens) : "off";
  return html`<form class="sset-ctx-form"><label class="llmctx-field"><span>Apply</span><span class="select-wrap"><select
    name="apply">${option(DEFAULT, `${DEFAULT} (${summary.apply})`, own.apply)}${APPLIES.map((a) => option(a, a, own.apply))}</select
    ></span></label><label class="llmctx-field"><span>Budget</span><input name="budget" type="text" inputmode="numeric"
    autocomplete="off" placeholder=${`${DEFAULT} (${budget}): 64000, 64k or off`} .value=${own.budget}></label
    ><div class="ctx-pop-error" role="alert" ?hidden=${!error}>${error || ""}</div
    ><div class="ctx-pop-actions"><button type="submit" class="llmctx-set">Set</button></div></form>`;
}

// A choice whose row is hidden (the picked model has no values for it).
const sentAnywayTemplate = (text, act) => html`<div class="sset-anyway ctx-pop-meta">${text}
  <button type="button" class="sset-link" data-act=${act}>Clear</button></div>`;

// The main view. +state+: {thinking: {summary, choice}, llmContext: {summary,
// choice}, review: subjects or null (no review row), more: the disclosure
// open, error: the context Set's}.
export function panelTemplate({ thinking, llmContext, review = null, more = false, error = null }) {
  const think = thinkingSegments(thinking.summary, thinking.choice);
  const ctx = contextSegments(llmContext.summary, llmContext.choice);
  const ctxAnyway = !ctx && contextWords(llmContext.choice);
  const reviewChip = review?.length ? reviewChipModel(review) : null;
  return html`<div class="ctx-pop-head"><strong>New session</strong
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    >${think ? segmentsTemplate("think", "Thinking", think, "think") : nothing
    }${!think && thinking.choice ? sentAnywayTemplate(`Thinking ${thinking.choice}: ${NO_THINKING}.`, "think-clear") : nothing
    }${ctx ? html`${segmentsTemplate("ctx", "Context", ctx, "ctx")}<div class="sset-ctx-more"><button type="button" class="sset-link"
      data-act="ctx-more" aria-expanded=${more ? "true" : "false"}>Apply and budget ${more ? "▾" : "▸"}</button></div
      >${more ? contextMoreTemplate(llmContext.summary, llmContext.choice, error) : nothing}` : nothing
    }${ctxAnyway ? sentAnywayTemplate(`Context ${ctxAnyway}: ${NO_LLM_CONTEXT}.`, "ctx-clear") : nothing
    }${review ? html`${think || ctx ? html`<hr class="sset-rule">` : nothing}<div class="sset-review">${reviewChip
      ? html`<span class="sset-review-set" title=${reviewChip.title}>Review: ${reviewChip.text.replace(/^review: /, "")}</span
        ><button type="button" class="sset-link" data-act="review">Edit</button><button type="button" class="sset-link"
        data-act="review-clear">Remove</button>`
      : html`<button type="button" class="sset-link" data-act="review" title=${reviewChipModel([]).title}>Review files…</button>`}</div>`
      : nothing
    }<div class="ctx-pop-meta">${NOTE}</div>`;
}

// The panel on chip_popover.js' shell, a bottom sheet on a phone. +el+:
// where ⚙ is (its clicks are delegated); +button+: ⚙ (the panel opens at it,
// and focus goes back to it whichever opener was clicked); +openers+: the
// selector of every element that opens it (⚙ and the override chips: a click
// there is not a click outside). +thinking+ / +llmContext+: {summary(),
// choice(), choose(next)}; +review+: {choice(), choose(subjects)}, or null
// (no review row).
// @return {open(view), toggle(view), close, refresh, refuse(message), isOpen}
export function createStartSettings({ el, button, openers = `#${button.id}`, thinking, llmContext, review = null,
                                      doc = document, win = window }) {
  // "main" or "review"; the disclosure; the context Set's error; the review
  // form's error and text as typed.
  let view = "main";
  let more = false;
  let error = null;
  let reviewError = null;
  let reviewText = null;

  function draw() {
    if (view === "review") {
      render(reviewFormTemplate(review.choice(), { error: reviewError, text: reviewText, back: true }), shell.pop);
    } else {
      render(panelTemplate({
        thinking: { summary: thinking.summary(), choice: thinking.choice() },
        llmContext: { summary: llmContext.summary(), choice: llmContext.choice() },
        review: review ? review.choice() : null, more, error,
      }), shell.pop);
    }
    shell.replace();
  }

  // Focus inside on open (the popover sits at the end of <body>, so Tab
  // from ⚙ wouldn't reach it): the pressed segment of the first row, else
  // the first button; the review view's text field.
  function focusInside() {
    const pop = shell.pop;
    const at = view === "review" ? pop.querySelector("textarea")
      : pop.querySelector(".sset-seg [aria-pressed=true]") || pop.querySelector(".sset-link, .sset-seg button");
    at?.focus();
  }

  function switchTo(next) {
    view = next;
    draw();
    if (next === "review") focusInside();
    else shell.pop.querySelector("[data-act=review]")?.focus();
  }

  function pickContext(changes) {
    const initial = ownValues({ own: llmContext.choice() });
    let next;
    try {
      next = mergeChoice(llmContext.choice(), { ...initial, ...changes }, initial);
    } catch (err) {
      error = err.message;
      return draw();
    }
    error = null;
    llmContext.choose(next);
    draw();
  }

  function clearContext() {
    error = null;
    llmContext.choose(null);
  }

  function act(name) {
    const [what, value] = name.split(/:(.*)/s);
    if (what === "think") thinking.choose(value === DEFAULT ? null : value);
    else if (what === "think-clear") thinking.choose(null);
    // "default" follows the model for the whole context, apply and budget
    // too (as Thinking's does): the pressed segment and the chip agree.
    else if (what === "ctx" && value === DEFAULT) clearContext();
    else if (what === "ctx") return pickContext({ strategy: value });
    else if (what === "ctx-clear") llmContext.choose(null);
    else if (what === "ctx-more") more = !more;
    else if (what === "review") return switchTo("review");
    else if (what === "back") {
      reviewError = null;
      reviewText = null;
      return switchTo("main");
    } else if (what === "review-clear" || what === "clear") {
      review.choose([]);
      reviewError = null;
      reviewText = null;
      if (view === "review") return switchTo("main");
    } else return;
    draw();
  }

  function submit(form) {
    if (form.classList.contains("sset-ctx-form")) {
      return pickContext({ apply: form.elements.apply.value, budget: form.elements.budget.value });
    }
    const typed = form.elements.subjects?.value || "";
    const read = readSubjects(typed);
    if (read.error) {
      reviewError = read.error;
      reviewText = typed;
      return draw();
    }
    review.choose(read.subjects);
    reviewError = null;
    reviewText = null;
    switchTo("main");
  }

  const shell = createChipPopover({
    id: "startSettingsPopover", className: "ctx-popover start-settings", width: 440, el, anchor: `#${button.id}`, openers,
    summary: () => ({}), sheet: true, expands: true, modal: true, label: PANEL_LABEL, doc, win,
    show: (_data, opening) => {
      if (opening) {
        const choice = llmContext.choice();
        more = !!(choice?.apply || typeof choice?.budget_tokens === "number");
      }
      draw();
    },
    onOpen: focusInside,
    onClose: () => {
      view = "main";
      error = null;
      reviewError = null;
      reviewText = null;
    },
    onSubmit: submit,
    onAct: act,
  });
  // An edit makes the context Set's error stale.
  shell.pop.addEventListener("input", (e) => {
    if (error && e.target.closest(".sset-ctx-form")) {
      error = null;
      draw();
    }
  });

  // +from+: the opener clicked (focus goes back to it), ⚙ by default.
  function open(at = "main", from = button) {
    view = review ? at : "main";
    if (shell.isOpen()) {
      draw();
      focusInside();
    } else {
      shell.open(button, { from });
    }
  }

  return {
    open,
    // An override chip's click: opens the panel (on +at+'s view), or closes it.
    toggle: (at = "main", from = button) => (shell.isOpen() ? shell.close() : open(at, from)),
    close: () => shell.close(),
    isOpen: () => shell.isOpen(),
    // The picked model changed (its default labels, which rows show).
    refresh: () => { if (shell.isOpen()) draw(); },
    // Start refused the review files (400 invalid_review): said in the
    // review view, opened at the files chosen.
    refuse: (message) => {
      reviewError = message;
      reviewText = null;
      open("review");
    },
  };
}
