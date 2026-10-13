// A tool call's full command in a richer UI than the TUI's params line:
// the server's view (ToolView: an execute/task_create's command uncut up to
// 8,000 chars, the call's cwd: argument). lit-html templates for the tool
// row (turn_html.js toolRowTemplate, live and reloaded alike).
import { html, nothing } from "./vendor/lit-html.js";
import { copyButtonTemplate } from "./copy.js";

// What a row's title hovers: the full command when the call has one,
// else the params line when the row shows a title in its place.
export function rowHover(row) {
  if (row?.view?.command) return row.view.command;
  return row?.title && row?.params ? row.params : "";
}

// The expanded row's command block: "in <cwd>" when the call gave one (as
// given: execute's may be relative to the project root), the command as
// written (whitespace kept, its own scroll), a copy button, and a line
// saying how much a cut command left out. nothing for a call without a view.
//
// A view with steps (CommandSteps) shows them in the command's place, its
// leading cd as one more "in" tag, and a "raw" toggle (a checkbox, CSS
// only, so a live and a reloaded row behave alike; beside the first step
// when there's no "in" tag) that swaps the steps for the command as
// written. The copy button copies the raw command
// either way. A view without steps (the parser's fallback) is the raw
// block alone: nothing hides the command.
//
// +title+ is the row's: the model's description of the command, when it
// gave one, cut to fit. The block starts with the whole description when
// the title is cut, never in place of the command.
export function commandBlockTemplate(view, title = null) {
  const command = view?.command;
  if (!command) return nothing;
  const desc = view.description && view.description !== title
    ? html`<div class="activity-command-desc">${view.description}</div>`
    : nothing;
  const steps = Array.isArray(view.steps) && view.steps.length ? view.steps : null;
  const dirs = [view.cwd, steps && view.cd].filter(Boolean);
  const where = dirs.length
    ? html`in ${dirs.map((d, i) => html`${i ? html` <span class="activity-command-sep">›</span> ` : nothing}<span>${d}</span>`)}`
    : null;
  const cut = view.truncated
    ? html`<div class="activity-command-cut">… (${command.length.toLocaleString("en-US")} of ${Number(view.chars || 0).toLocaleString("en-US")} chars)</div>`
    : nothing;
  const raw = html`<pre><code>${command}</code></pre>`;
  if (!steps) {
    const cwd = where ? html`<div class="activity-command-cwd">${where}</div>` : nothing;
    return html`<div class="activity-command code-wrap">${desc}${cwd}${raw}${copyButtonTemplate("code")}${cut}</div>`;
  }
  // No "in" tag: the toggle alone, floated beside the first step (an
  // empty line for it would sit above the steps). lit never binds the
  // checkbox: a user's toggle stays across a redraw.
  const toggle = html`<label class="activity-command-raw" title="Show the command as written"><input type="checkbox">raw</label>`;
  const head = where
    ? html`<div class="activity-command-head"><span class="activity-command-cwd">${where}</span>${toggle}</div>`
    : html`<div class="activity-command-head bare">${toggle}</div>`;
  return html`<div class="activity-command code-wrap has-steps">${desc}${head}${stepsTemplate(steps)}${raw}${copyButtonTemplate("code")}${cut}</div>`;
}

// What an op between two steps reads as: an arrow for "then" (&&, ;, a
// new line, a pipe), "else" for ||, "&" for one put in the background.
const OP_GLYPHS = { "&&": "→", ";": "→", "\n": "→", "|": "→", "|&": "→", "||": "else", "&": "&" };
const OP_NAMES = { "\n": "new line", "&": "after starting the step before in the background" };

function opTemplate(op) {
  if (!op) return html`<span class="step-op"></span>`;
  const glyph = OP_GLYPHS[op] || op;
  const name = OP_NAMES[op] || op;
  return html`<span class=${`step-op${op === "||" ? " else" : ""}`} title=${name}>${glyph}</span>`;
}

// A step's redirections to or from nowhere (2>&1, 2>/dev/null, </dev/null),
// dimmed: plumbing, not what the step does.
const PLUMBING = /(^|\s)(\d*>&\d+|&>\/dev\/null|\d*>>?\s*\/dev\/null|<\s*\/dev\/null)(?=\s|$)/g;

export function stepTextTemplate(text) {
  const out = [];
  let at = 0;
  for (const m of String(text).matchAll(PLUMBING)) {
    const start = m.index + m[1].length;
    out.push(text.slice(at, start), html`<span class="step-plumbing">${m[2]}</span>`);
    at = start + m[2].length;
  }
  out.push(String(text).slice(at));
  return out;
}

function heredocLabel({ tag, lines }) {
  return `${tag} · ${Number(lines)} ${lines === 1 ? "line" : "lines"}`;
}

// A step's heredoc chip: the first heredoc's tag and size, and "+N" for
// the others when the step has more (CommandSteps' heredocs:, as gh api
// -f body="$(cat <<EOF …)" -f title="$(cat <<EOF …)"), as a title with
// more steps reads "+N"; the hover lists them all. nothing without one.
export function heredocChip(step) {
  if (!step?.heredoc) return nothing;
  const all = Array.isArray(step.heredocs) && step.heredocs.length > 1 ? step.heredocs : [step.heredoc];
  const more = all.length > 1 ? ` +${all.length - 1}` : "";
  const title = all.length > 1
    ? `${all.length} heredocs: ${all.map(heredocLabel).join(", ")}; their text in the raw command`
    : "a heredoc: its text in the raw command";
  return html`<span class="step-chip heredoc" title=${title}>${heredocLabel(all[0])}${more}</span>`;
}

// The steps as a list: a label as a small heading above its step, the op
// that links a step to the one before, its text, its limit and heredoc
// as chips (beside the text, below it when the row is narrow).
export function stepsTemplate(steps) {
  const items = steps.map((step) => {
    const label = step.label ? html`<li class="step-label">${step.label}</li>` : nothing;
    const limit = step.limit ? html`<span class="step-chip" title="output limited">${step.limit}</span>` : nothing;
    return html`${label}<li class="activity-step">${opTemplate(step.op)}<span class="step-body"><code>${stepTextTemplate(step.text)}</code>${limit}${heredocChip(step)}</span></li>`;
  });
  return html`<ol class="activity-steps">${items}</ol>`;
}
