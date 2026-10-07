// The session bar's LLM context chip: the strategy the next turn runs under
// ("llm ctx stale,forget"; "· session" when the session set its own), and a
// popover that sets the session's own strategy, apply rule and budget by
// running /llm-context in its worker (the command's reply shows in the
// conversation, like a typed one). The values and where each came from are
// the session's llm_context (LLMContextStrategy::Explained#summary: the
// worker's snapshot, a command_ran, or the server's own reading of the
// session file).

export const STRATEGIES = [
  { value: "none", label: "none" },
  { value: "stale", label: "stale" },
  { value: "stale,forget", label: "stale + forget (experimental)" },
];
export const APPLIES = ["payoff", "next_request", "turn_end"];

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

// The chip: its text, tooltip and whether the session set its own; null
// without a summary (an older worker).
export function chipModel(summary) {
  if (!summary || !summary.strategy) return null;
  const own = summary.strategy_source === "session" || !!summary.own;
  const budget = summary.budget_tokens ? `${summary.budget_tokens} tokens` : "off";
  const title = `LLM context strategy: ${summary.strategy} (${summary.strategy_where}); apply ${summary.apply} ` +
    `(${summary.apply_where}); budget ${budget} (${summary.budget_where}). Click to change it for this session.`;
  return { text: `llm ctx ${summary.strategy}${own ? " · session" : ""}`, title, own };
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

export function formHtml(summary, escapeHtml, { running = false } = {}) {
  const own = ownValues(summary);
  const follow = (field) => (summary[`${field}_source`] === "session" ? "follow the model" : `follow the model (${summary[field]})`);
  return `<form class="llmctx-form"><div class="ctx-pop-head"><strong>LLM context</strong>` +
    `<span class="ctx-pop-kind">this session</span>` +
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
    `<div class="ctx-pop-meta">From the next turn's start. Turning forget on or off re-reads the whole prompt once.` +
    `${running ? " A turn is running: set it when it ends." : ""}</div>` +
    `<div class="ctx-pop-actions"><button type="button" class="ctx-pop-detach" data-act="reset">follow the model</button>` +
    `<button type="submit" class="llmctx-set"${running ? " disabled" : ""}>Set</button></div></form>`;
}

// The chip's popover. el: where the chip is drawn (#infoText, redrawn every
// tick: clicks are delegated); summary(): the open session's llm_context;
// session(): the open session's id; running(): a turn runs; run(line):
// sends the command.
export function createLlmContextControl({ el, escapeHtml, summary, session = () => null, running = () => false, run,
                                          doc = document, win = window }) {
  const pop = doc.createElement("div");
  pop.id = "llmContextPopover";
  pop.className = "ctx-popover llmctx-popover";
  pop.setAttribute("role", "dialog");
  pop.hidden = true;
  doc.body.appendChild(pop);
  // The values the form opened with, and the session it is for.
  let initial = null;
  let openFor = null;

  function place(anchor) {
    const rect = anchor.getBoundingClientRect();
    const width = Math.min(360, win.innerWidth - 32);
    pop.style.width = `${width}px`;
    pop.style.left = `${Math.max(16, Math.min(rect.left, win.innerWidth - width - 16))}px`;
    pop.style.bottom = `${Math.max(16, win.innerHeight - rect.top + 8)}px`;
  }

  function open(anchor) {
    const data = summary();
    if (!data) return;
    initial = ownValues(data);
    openFor = session();
    pop.innerHTML = formHtml(data, escapeHtml, { running: running() });
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
    const anchor = e.target.closest(".llmctx-chip");
    if (!anchor) return;
    e.stopPropagation();
    if (isOpen()) close();
    else open(anchor);
  });
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    const form = e.target;
    const line = commandLine({ strategy: form.elements.strategy.value, apply: form.elements.apply.value,
                               budget: form.elements.budget.value }, initial);
    close();
    if (line) run(line);
  });
  pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "close") close();
    else if (act === "reset") {
      close();
      run(commandLine());
    }
  });
  doc.addEventListener("click", (e) => {
    if (isOpen() && !pop.contains(e.target) && !e.target.closest?.(".llmctx-chip")) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) close();
  });

  return { close, refresh, get open() { return isOpen(); } };
}
