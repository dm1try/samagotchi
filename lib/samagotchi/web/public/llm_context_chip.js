// The session bar's LLM context chip: the strategy the next turn runs under
// ("llm ctx stale,forget"; "· session" when the session set its own), and a
// popover that sets the session's own strategy, apply rule and budget by
// running /llm-context in its worker (the command's reply shows in the
// conversation, like a typed one). The values and where each came from are
// the session's llm_context (LLMContextStrategy::Explained#summary: the
// worker's snapshot, a command_ran, or the server's own reading of the
// session file).
//
// The start page has one too (kind "new chat"): it shows the picked
// model's values (GET /api/models' llm_context) and its form keeps a
// choice for the next create only (POST /api/sessions' llm_context), never
// remembered: nothing is sent unless the user sets one.

export const STRATEGIES = [
  { value: "none", label: "none" },
  { value: "stale", label: "stale" },
  { value: "stale,forget", label: "stale + forget (experimental)" },
];
export const APPLIES = ["payoff", "next_request", "turn_end"];
export const SESSION = "session";
export const NEW_CHAT = "new chat";

const DEFAULT = "default";
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

// The start page's choice for the new chat ({strategy: [layers], apply,
// budget_tokens}, the session file's shape; 0 is off) laid over the
// model's summary: what the chip shows, with the chosen fields' source
// "session" ("the new chat"). The model's own summary without a choice.
export function withChoice(summary, choice) {
  if (!summary || !choice) return summary;
  const merged = { ...summary, own: choice };
  // (the budget's source and where are budget_source / budget_where)
  const set = (field, key, value) => Object.assign(merged, { [key]: value, [`${field}_source`]: SESSION,
                                                            [`${field}_where`]: "the new chat" });
  if (Array.isArray(choice.strategy)) set("strategy", "strategy", strategyValue(choice.strategy));
  if (choice.apply) set("apply", "apply", choice.apply);
  if (typeof choice.budget_tokens === "number") {
    set("budget", "budget_tokens", choice.budget_tokens > 0 ? choice.budget_tokens : null);
  }
  return merged;
}

// The chip: its text, tooltip and whether the session (or the new chat)
// set its own; null without a summary (an older worker).
export function chipModel(summary, { kind = SESSION } = {}) {
  if (!summary || !summary.strategy) return null;
  const own = summary.strategy_source === "session" || !!summary.own;
  const budget = summary.budget_tokens ? `${summary.budget_tokens} tokens` : "off";
  const what = kind === NEW_CHAT ? "the new chat" : "this session";
  const title = `LLM context strategy: ${summary.strategy} (${summary.strategy_where}); apply ${summary.apply} ` +
    `(${summary.apply_where}); budget ${budget} (${summary.budget_where}). Click to change it for ${what}.`;
  return { text: `llm ctx ${summary.strategy}${own ? ` · ${kind}` : ""}`, title, own };
}

export function chipHtml(summary, escapeHtml) {
  const chip = chipModel(summary);
  if (!chip) return "";
  return `<button type="button" class="model llmctx-chip${chip.own ? " own" : ""}" title="${escapeHtml(chip.title)}" ` +
    `aria-haspopup="dialog">${escapeHtml(chip.text)}</button>`;
}

// The /llm-context line for the form's values. With +initial+ (the values
// the form opened with) only the fields the user changed go, so a value the
// form can't show is never unset by a Set; null when nothing changed.
// Without it every field goes, "default" for one left to the model, and all
// of them default is a reset.
export function commandLine({ strategy = DEFAULT, apply = DEFAULT, budget = "" } = {}, initial = null) {
  const words = { strategy, apply, budget: String(budget).trim() || DEFAULT };
  const was = initial && { strategy: initial.strategy, apply: initial.apply, budget: String(initial.budget).trim() || DEFAULT };
  const fields = Object.keys(words).filter((field) => !was || words[field] !== was[field]);
  if (!fields.length) return null;
  if (!was && fields.every((field) => words[field] === DEFAULT)) return "/llm-context reset";
  return `/llm-context ${fields.map((field) => `${field} ${words[field]}`).join(" ")}`;
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

// The new chat's choice after a Set: +choice+ with the fields the user
// changed (vs +initial+, the values the form opened with) applied, a field
// set back to default dropped; null when nothing is left. Throws on a
// budget that isn't one.
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
      if (tokens === null) throw new Error("A budget is a number of tokens from 4000 (4k) to 10000000, or off.");
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

// The strategy list, with the session's own value when it isn't one of them
// (forget alone, a newer chi's layer).
export function strategyOptions(chosen) {
  if (chosen === DEFAULT || STRATEGIES.some((s) => s.value === chosen)) return STRATEGIES;
  return [...STRATEGIES, { value: chosen, label: chosen }];
}

function option(value, label, chosen, escapeHtml) {
  return `<option value="${escapeHtml(value)}"${value === chosen ? " selected" : ""}>${escapeHtml(label)}</option>`;
}

// The popover's form: the values now (each with its source), and the
// session's own to change.
export function nowText(summary) {
  const budget = summary.budget_tokens ? `${summary.budget_tokens} tokens` : "off";
  return `Now: ${summary.strategy} (${summary.strategy_where}) · apply ${summary.apply} (${summary.apply_where}) · ` +
    `budget ${budget} (${summary.budget_where})`;
}

// For the new chat (kind NEW_CHAT), +summary+ is the model's and +choice+
// the values the form shows.
export function formHtml(summary, escapeHtml, { running = false, kind = SESSION, choice = null } = {}) {
  const fresh = kind === NEW_CHAT;
  const own = fresh ? ownValues({ own: choice }) : ownValues(summary);
  const follow = (field) => (summary[`${field}_source`] === "session" ? "follow the model" : `follow the model (${summary[field]})`);
  const when = fresh ? "For the new chat's first turn on; not remembered for the next one."
    : "From the next turn's start. Turning forget on or off re-reads the whole prompt once.";
  return `<form class="llmctx-form"><div class="ctx-pop-head"><strong>LLM context</strong>` +
    `<span class="ctx-pop-kind">${fresh ? NEW_CHAT : "this session"}</span>` +
    `<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>` +
    `<div class="ctx-pop-meta llmctx-now">${escapeHtml(nowText(summary))}</div>` +
    `<label class="llmctx-field"><span>Strategy</span><select name="strategy">` +
    option(DEFAULT, follow("strategy"), own.strategy, escapeHtml) +
    strategyOptions(own.strategy).map((s) => option(s.value, s.label, own.strategy, escapeHtml)).join("") + `</select></label>` +
    `<label class="llmctx-field"><span>Apply</span><select name="apply">` +
    option(DEFAULT, follow("apply"), own.apply, escapeHtml) +
    APPLIES.map((a) => option(a, a, own.apply, escapeHtml)).join("") + `</select></label>` +
    `<label class="llmctx-field"><span>Budget</span><input name="budget" type="text" inputmode="numeric" autocomplete="off" ` +
    `placeholder="follow the model (64000, 64k or off)" value="${escapeHtml(own.budget)}"></label>` +
    `<div class="ctx-pop-error llmctx-error" hidden></div>` +
    `<div class="ctx-pop-meta">${when}${running ? " A turn is running: set it when it ends." : ""}</div>` +
    `<div class="ctx-pop-actions"><button type="button" class="ctx-pop-detach" data-act="reset">follow the model</button>` +
    `<button type="submit" class="llmctx-set"${running ? " disabled" : ""}>Set</button></div></form>`;
}

const EDGE = 16;
const GAP = 8;

// Where the popover goes for the chip's +rect+: above it, or below when
// the room above is short of its height and below has more; capped to the
// room on that side (it scrolls), never past the window's edges.
// @return {{left, top?, bottom?, maxHeight?}}
export function popoverPlace(rect, { width, height, innerWidth, innerHeight }) {
  const left = Math.max(EDGE, Math.min(rect.left, innerWidth - width - EDGE));
  const above = rect.top - GAP - EDGE;
  const below = innerHeight - rect.bottom - GAP - EDGE;
  const down = height > above && below > above;
  const room = Math.max(0, down ? below : above);
  const place = down ? { left, top: rect.bottom + GAP } : { left, bottom: Math.max(EDGE, innerHeight - rect.top + GAP) };
  return height > room ? { ...place, maxHeight: room } : place;
}

// The chip's popover. el: where the chip is drawn (#infoText, redrawn every
// tick: clicks are delegated); summary(): the open session's llm_context;
// session(): the open session's id; running(): a turn runs; run(line):
// sends the command.
// The start page's (kind NEW_CHAT): summary() is the picked model's,
// choice() the pending choice, and choose(next) takes a Set's (null for
// "follow the model") instead of a command running. id and anchor (the
// chip's selector) keep the two controls apart.
export function createLlmContextControl({ el, escapeHtml, summary, session = () => null, running = () => false, run,
                                          kind = SESSION, choice = () => null, choose = null,
                                          id = "llmContextPopover", anchor: anchorSel = ".llmctx-chip",
                                          doc = document, win = window }) {
  const fresh = kind === NEW_CHAT;
  const pop = doc.createElement("div");
  pop.id = id;
  pop.className = "ctx-popover llmctx-popover";
  pop.setAttribute("role", "dialog");
  pop.hidden = true;
  doc.body.appendChild(pop);
  // The values the form opened with, and the session it is for.
  let initial = null;
  let openFor = null;

  function place(anchor) {
    const width = Math.min(360, win.innerWidth - 32);
    pop.style.width = `${width}px`;
    pop.style.maxHeight = "";
    const at = popoverPlace(anchor.getBoundingClientRect(), { width, height: pop.offsetHeight,
                                                              innerWidth: win.innerWidth, innerHeight: win.innerHeight });
    pop.style.left = `${at.left}px`;
    pop.style.top = at.top === undefined ? "" : `${at.top}px`;
    pop.style.bottom = at.bottom === undefined ? "" : `${at.bottom}px`;
    if (at.maxHeight !== undefined) pop.style.maxHeight = `${at.maxHeight}px`;
  }

  function open(anchor) {
    const data = summary();
    if (!data) return;
    initial = fresh ? ownValues({ own: choice() }) : ownValues(data);
    openFor = session();
    pop.innerHTML = formHtml(data, escapeHtml, { running: running(), kind, choice: choice() });
    pop.hidden = false;
    place(anchor);
  }

  function close() {
    pop.hidden = true;
    initial = null;
    openFor = null;
  }

  function isOpen() { return !pop.hidden; }

  // A new summary (a command_ran, a re-read): an open form keeps what the
  // user typed; only its "Now:" line and Set's state follow. Another
  // session closes it.
  function refresh() {
    if (!isOpen()) return;
    const data = summary();
    if (!data || session() !== openFor) return close();
    const now = pop.querySelector(".llmctx-now");
    if (now) now.textContent = nowText(data);
    const set = pop.querySelector(".llmctx-set");
    if (set) set.disabled = running();
  }

  el.addEventListener("click", (e) => {
    const anchor = e.target.closest(anchorSel);
    if (!anchor) return;
    e.stopPropagation();
    if (isOpen()) close();
    else open(anchor);
  });
  // An edit makes an error the last Set showed stale.
  const clearError = () => {
    const error = pop.querySelector(".llmctx-error");
    if (error && !error.hidden) { error.hidden = true; error.textContent = ""; }
  };
  pop.addEventListener("input", clearError);
  pop.addEventListener("change", clearError);
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    const form = e.target;
    const values = { strategy: form.elements.strategy.value, apply: form.elements.apply.value,
                     budget: form.elements.budget.value };
    if (fresh) {
      let next;
      try {
        next = mergeChoice(choice(), values, initial);
      } catch (err) {
        const error = pop.querySelector(".llmctx-error");
        error.textContent = err.message;
        error.hidden = false;
        return;
      }
      close();
      choose(next);
      return;
    }
    const line = commandLine(values, initial);
    close();
    if (line) run(line);
  });
  pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "close") close();
    else if (act === "reset") {
      close();
      if (fresh) choose(null);
      else run(commandLine());
    }
  });
  doc.addEventListener("click", (e) => {
    if (isOpen() && !pop.contains(e.target) && !e.target.closest?.(anchorSel)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) close();
  });

  return { close, refresh, get open() { return isOpen(); } };
}
