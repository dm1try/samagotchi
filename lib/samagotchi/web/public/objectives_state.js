// Where a move says its objective stands (pure, no DOM): a move's state
// (Tools::ObjectivesTool: progress, blocked or done; done is the agent's claim,
// never the item's status) and its words, and its backing's flag. A module of its own, not new exports of
// objectives_model.js: static JS is cached at unversioned URLs, and an existing
// module importing a new export of another existing one blanks a page with a
// mixed cache. See docs/internals/objectives.md.

const WORDS = { blocked: "blocked", done: "claims done" };

// A tool row's params line carries a blocked or done state before its note
// (ToolActivity#objectives_state_param); the title doesn't (an older page reads it).
const PARAMS_STATE = /^id="(?:[^"\\]|\\.)*" state="(blocked|done)" note=/;

// The words a state adds: null for progress, none or one this page doesn't know.
export function stateWord(state) {
  return Object.hasOwn(WORDS, state) ? WORDS[state] : null;
}

// The state a row's params line names: "blocked", "done" or null.
export function stateOfParams(params) {
  return PARAMS_STATE.exec(String(params ?? ""))?.[1] ?? null;
}

// A move's backing (Objectives::Backing, derived from its turn's runs) as the
// muted mark's words, only when it is flagged: a done move whose turn's last
// command failed, or that edited after it. null otherwise.
export function backingText(move) {
  const backing = move?.backing;
  if (!backing?.unbacked) return null;
  return backing.command === "failed" ? "not backed: the last command failed" : "not backed: edited after the last command ran";
}
