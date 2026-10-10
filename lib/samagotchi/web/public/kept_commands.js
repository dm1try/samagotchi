// Command bubbles (/help, /model, /stats, /llm-context …) live only in the
// page: the session saves just a `!cmd`'s output (a message, redrawn as its
// command bubble). A resync (a `!cmd`, a `!rollback`, a dropped stream)
// redraws the history from the server, so the page keeps its own command
// bubbles across it: each one's anchor is the prompts and saved shell
// commands before it, and it goes back after them in the redrawn history.
// A reload still drops them.
//
// +kinds+: the history's children in order, each "user" (a prompt bubble),
// "shell" (a `!cmd`'s bubble, which the redrawn history has too) or
// anything else.

// @return {{users: number, shells: number}} the anchor of kinds[index]
export function commandAnchor(kinds, index) {
  const before = kinds.slice(0, index);
  return {
    users: before.filter((k) => k === "user").length,
    shells: before.filter((k) => k === "shell").length,
  };
}

// The index to insert a kept bubble at: before the first prompt or shell
// command past its anchor (it ran after its turn), else at the end (a
// history a !rollback made shorter too).
export function anchorInsertIndex(kinds, { users = 0, shells = 0 } = {}) {
  let seenUsers = 0;
  let seenShells = 0;
  for (let i = 0; i < kinds.length; i += 1) {
    if (kinds[i] === "user") {
      if (seenUsers >= users) return i;
      seenUsers += 1;
    } else if (kinds[i] === "shell") {
      if (seenShells >= shells) return i;
      seenShells += 1;
    }
  }
  return kinds.length;
}

const SHELL_LINE = /^!\s*\S/;
const ROLLBACK_LINE = /^!rollback(\s|$)/;

// Whether a command bubble's line is kept across a resync: a `!cmd`'s is
// redrawn from its saved message (keeping it too would show it twice).
export function isShellCommandLine(line) {
  const text = String(line ?? "");
  return SHELL_LINE.test(text) && !ROLLBACK_LINE.test(text);
}

export function keepsCommandBubble(line) {
  return !isShellCommandLine(line);
}
