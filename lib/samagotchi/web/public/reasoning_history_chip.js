// The session bar's reasoning history chip: which of its own reasoning the
// session's model gets back from the next turn on ("reasoning all";
// "· session" when the session set its own), and a popover with a level
// select that runs /reasoning-history in the session's worker. The summary
// is the session's reasoning_history (SettingExplained#summary; null on a
// native host, which ignores it, or from an older worker: no chip then).
// A config on level_chip.js.

import * as level from "./level_chip.js";
import { html, nothing } from "./vendor/lit-html.js";

export const LEVELS = ["drop", "turn", "all"];

export const CONFIG = Object.freeze({
  name: "Reasoning history",
  prefix: "reasoning",
  command: "/reasoning-history",
  levels: LEVELS,
  anchor: "[data-rh-chip]",
  formClass: "rh-form",
  popoverClass: "rh-popover",
  nowClass: "rh-now",
  when: () => "From the next turn's start. A change to or from all makes the server read the conversation again.",
});

export function chipModel(summary) {
  return level.chipModel(CONFIG, summary);
}

// The session bar's chip (a lit-html template; info_bar.js), nothing
// without a summary.
export function chipTemplate(summary) {
  const chip = chipModel(summary);
  if (!chip) return nothing;
  return html`<button type="button" class=${`model rh-chip${chip.own ? " own" : ""}`} title=${chip.title} data-rh-chip aria-haspopup="dialog">${chip.text}</button>`;
}

export function commandLine(choice, initial = null) {
  return level.commandLine(CONFIG, choice, initial);
}

export function formTemplate(summary, opts) {
  return level.formTemplate(CONFIG, summary, opts);
}

// The chip's popover in the session bar (level_chip.js createLevelControl).
export function createReasoningHistoryControl({ id = "reasoningHistoryPopover", ...opts }) {
  return level.createLevelControl({ cfg: CONFIG, id, ...opts });
}
