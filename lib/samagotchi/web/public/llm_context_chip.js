// The session's LLM context (LLMContextStrategy::Explained#summary: the
// worker's snapshot, a command_ran, or the server's own reading of the
// session file) as the settings panels read and change it: the session's own
// values (ownValues), the /llm-context line a session bar's pick runs in its
// worker (commandLine; settings_chip.js), a typed budget (parseBudget).
//
// The start page's new session sets its strategy in the ⚙ panel
// (start_settings.js): mergeChoice and choiceWords are its, a choice in the
// session file's shape sent as POST /api/sessions' llm_context words.

export const APPLIES = ["payoff", "next_request", "turn_end"];

const DEFAULT = "default";
// What a budget parseBudget refuses gets, under the fields.
export const BUDGET_ERROR = "A budget is a number of tokens from 4000 (4k) to 10000000, or off.";
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

// The /llm-context line for the panel's values. With +initial+ (the
// session's own values, ownValues) only the fields that differ go, so a
// value the tap didn't touch is never unset; null when nothing changed.
// Without it every field goes, "default" for one left to the model, and all
// of them default is a reset. With --yes: the panel states what a change
// costs, so a pick is the choice (no confirm step), as level_chip.js's.
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
      if (tokens === null) throw new Error(BUDGET_ERROR);
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
