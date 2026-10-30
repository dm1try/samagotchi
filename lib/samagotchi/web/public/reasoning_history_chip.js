// Reasoning history as a level setting (level_chip.js): which of its own
// reasoning the session's model gets back from the next turn on. The session
// bar's ⚙ panel draws its row on a chat host (settings_chip.js; the summary
// is null on a native host, which ignores it, or from an older worker: no
// row then) and runs /reasoning-history in the session's worker.

import * as level from "./level_chip.js";

export const LEVELS = ["drop", "turn", "all"];

export const CONFIG = Object.freeze({
  name: "Reasoning history",
  prefix: "reasoning",
  command: "/reasoning-history",
  levels: LEVELS,
  cost: "A reasoning history change to or from all makes the server read the conversation again.",
});

// The /reasoning-history line for a level, with --yes; null when it is the
// session's (+initial+).
export function commandLine(choice, initial = null) {
  return level.commandLine(CONFIG, choice, initial);
}
