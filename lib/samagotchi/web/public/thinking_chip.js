// The session bar's thinking chip: the level the next turn runs at ("think
// low"; "· session" when the session set its own), and a popover with a
// level select that runs /thinking in the session's worker (the command's
// reply shows in the conversation, like a typed one). The level and where
// it came from are the session's thinking (SettingExplained#summary:
// {level, source, own}; the worker's snapshot, a command_ran, or the
// server's own reading of the session file). A config on level_chip.js.
//
// The start page has one too (kind "new chat"): it shows the picked
// model's level (GET /api/models' thinking) and keeps a choice for the
// next create only (POST /api/sessions' thinking), never remembered:
// nothing is sent unless the user sets one.

import { SESSION } from "./llm_context_chip.js";
import * as level from "./level_chip.js";
import { html, nothing } from "./vendor/lit-html.js";

export const LEVELS = ["off", "low", "medium", "high"];

export const CONFIG = Object.freeze({
  name: "Thinking",
  prefix: "think",
  command: "/thinking",
  levels: LEVELS,
  anchor: "[data-think-chip]",
  formClass: "think-form",
  popoverClass: "think-popover",
  nowClass: "think-now",
  when: (fresh) => (fresh ? "For the new chat's first turn on; not remembered for the next one."
    : "From the next turn's start. On Gemma the whole prompt is read again; a hosted API reads the whole conversation again."),
});

export const { nowText } = level;

// The new chat's choice (a level, or null) laid over the model's summary:
// what the chip shows. The model's own summary without a choice.
export function withChoice(summary, choice) {
  if (!summary || !choice) return summary;
  return { ...summary, level: choice, source: SESSION, own: choice };
}

// The chip: its text, tooltip and whether the session (or the new chat)
// set its own; null without a summary (an older worker). The default with
// nothing set anywhere shows too ("think default"): the chip is where the
// level is set.
export function chipModel(summary, opts) {
  return level.chipModel(CONFIG, summary, opts);
}

// The session bar's chip (a lit-html template; info_bar.js), nothing
// without a summary.
export function chipTemplate(summary) {
  const chip = chipModel(summary);
  if (!chip) return nothing;
  return html`<button type="button" class=${`model think-chip${chip.own ? " own" : ""}`} title=${chip.title} data-think-chip aria-haspopup="dialog">${chip.text}</button>`;
}

// The /thinking line for a select value, with --yes (level_chip.js
// commandLine); null when it is what the form opened with.
export function commandLine(choice, initial = null) {
  return level.commandLine(CONFIG, choice, initial);
}

// The popover's form (level_chip.js formTemplate).
export function formTemplate(summary, opts) {
  return level.formTemplate(CONFIG, summary, opts);
}

// The chip's popover (level_chip.js createLevelControl); the start page's
// passes kind NEW_CHAT, choice and choose.
export function createThinkingControl({ id = "thinkingPopover", ...opts }) {
  return level.createLevelControl({ cfg: CONFIG, id, ...opts });
}
