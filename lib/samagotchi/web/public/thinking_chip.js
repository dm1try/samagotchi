// Thinking as a level setting (level_chip.js): the levels the settings
// panels' Thinking row offers (settings_panel.js; the start page's ⚙ panel,
// the session bar's, settings_chip.js) and the /thinking line a session's
// pick runs in its worker.

import * as level from "./level_chip.js";

export const LEVELS = ["off", "low", "medium", "high"];

export const CONFIG = Object.freeze({
  name: "Thinking",
  prefix: "think",
  command: "/thinking",
  levels: LEVELS,
  cost: "A thinking change: on Gemma the whole prompt is read again; a hosted API reads the whole conversation again.",
});

// The /thinking line for a level, with --yes (level_chip.js commandLine);
// null when it is the session's (+initial+).
export function commandLine(choice, initial = null) {
  return level.commandLine(CONFIG, choice, initial);
}
