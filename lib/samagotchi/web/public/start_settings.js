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

import { createChipPopover, SHEET_TALL } from "./chip_popover.js";
import { mergeChoice, ownValues } from "./llm_context_chip.js";
import { readSubjects, reviewChipModel, reviewFormTemplate } from "./review_start.js";
import {
  contextSegments, contextWords, DEFAULT, settingsPanelTemplate, thinkingSegments,
} from "./settings_panel.js";
import { render } from "./vendor/lit-html.js";

// The panel's rows (settings_panel.js), named here too: the start page and
// its specs read them from this module.
export { contextSegments, contextWords, DEFAULT, thinkingSegments };
export const NOTE = "For this new session only.";
export const PANEL_LABEL = "Session settings";
const NO_THINKING = "the picked model has no thinking setting; it is sent anyway";
const NO_LLM_CONTEXT = "the picked model has no LLM context values; it is sent anyway";

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

// The main view (settings_panel.js settingsPanelTemplate over the new
// session's choices). +state+: {thinking: {summary, choice}, llmContext:
// {summary, choice}, review: subjects or null (no review row), more: the
// disclosure open, error: the context Set's}.
export function panelTemplate({ thinking, llmContext, review = null, more = false, error = null }) {
  const think = thinkingSegments(thinking.summary, thinking.choice);
  const ctx = contextSegments(llmContext.summary, llmContext.choice);
  const ctxAnyway = !ctx && contextWords(llmContext.choice);
  return settingsPanelTemplate({
    heading: "New session",
    rows: [
      think ? { name: "think", label: "Thinking", segments: think, act: "think" } : null,
      !think && thinking.choice ? { anyway: `Thinking ${thinking.choice}: ${NO_THINKING}.`, act: "think-clear" } : null,
      ctx ? { name: "ctx", label: "Context", segments: ctx, act: "ctx",
              more: { open: more, summary: llmContext.summary, choice: llmContext.choice, error } } : null,
      ctxAnyway ? { anyway: `Context ${ctxAnyway}: ${NO_LLM_CONTEXT}.`, act: "ctx-clear" } : null,
    ],
    review,
    note: NOTE,
  });
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
    // Taller than a plain sheet: the Apply and budget fields or the review
    // form would push the note under the edge of a 60 % one.
    summary: () => ({}), sheet: true, sheetShare: SHEET_TALL, expands: true, modal: true, label: PANEL_LABEL, doc, win,
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
