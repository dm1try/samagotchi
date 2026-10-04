// A tool call's full command in a richer UI than the TUI's params line:
// the server's view (ToolView: an execute/task_create's command uncut up to
// 8,000 chars, the call's cwd: argument). Pure HTML builders, shared by the
// live row (turn_view.js fillActivityRow) and the reloaded one
// (reloadRowHtml), so the two can't differ.
import { copyButtonHtml } from "./copy.js";
import { escapeHtml } from "./format.js";

// What a row's title hovers: the full command when the call has one,
// else the params line when the row shows a title in its place.
export function rowHover(row) {
  if (row?.view?.command) return row.view.command;
  return row?.title && row?.params ? row.params : "";
}

// The expanded row's command block: "in <cwd>" when the call gave one (as
// given: execute's may be relative to the project root), the command as
// written (whitespace kept, its own scroll), a copy button, and a line
// saying how much a cut command left out. "" for a call without a view.
//
// A view with steps (CommandSteps) shows them in the command's place, its
// leading cd as one more "in" tag, and a "raw" toggle (a checkbox, CSS
// only, so a live and a reloaded row behave alike) that swaps the steps
// for the command as written. The copy button copies the raw command
// either way. A view without steps (the parser's fallback) is the raw
// block alone: nothing hides the command.
export function commandBlockHtml(view) {
  const command = view?.command;
  if (!command) return "";
  const steps = Array.isArray(view.steps) && view.steps.length ? view.steps : null;
  const dirs = [view.cwd, steps && view.cd].filter(Boolean);
  const where = dirs.length
    ? `in ${dirs.map((d) => `<span>${escapeHtml(d)}</span>`).join(" <span class=\"activity-command-sep\">›</span> ")}`
    : "";
  const cut = view.truncated
    ? `<div class="activity-command-cut">… (${command.length.toLocaleString("en-US")} of ${Number(view.chars || 0).toLocaleString("en-US")} chars)</div>`
    : "";
  const raw = `<pre><code>${escapeHtml(command)}</code></pre>`;
  if (!steps) {
    const cwd = where ? `<div class="activity-command-cwd">${where}</div>` : "";
    return `<div class="activity-command code-wrap">${cwd}${raw}${copyButtonHtml("code")}${cut}</div>`;
  }
  const head = `<div class="activity-command-head"><span class="activity-command-cwd">${where}</span>` +
    `<label class="activity-command-raw" title="Show the command as written"><input type="checkbox">raw</label></div>`;
  return `<div class="activity-command code-wrap has-steps">${head}${stepsHtml(steps)}${raw}${copyButtonHtml("code")}${cut}</div>`;
}

// What an op between two steps reads as: an arrow for "then" (&&, ;, a
// new line, a pipe), "else" for ||, "&" for one put in the background.
const OP_GLYPHS = { "&&": "→", ";": "→", "\n": "→", "|": "→", "|&": "→", "||": "else", "&": "&" };
const OP_NAMES = { "\n": "new line", "&": "after starting the step before in the background" };

function opHtml(op) {
  if (!op) return `<span class="step-op"></span>`;
  const glyph = OP_GLYPHS[op] || op;
  const name = OP_NAMES[op] || op;
  return `<span class="step-op${op === "||" ? " else" : ""}" title="${escapeHtml(name)}">${escapeHtml(glyph)}</span>`;
}

// A step's redirections to or from nowhere (2>&1, 2>/dev/null, </dev/null),
// dimmed: plumbing, not what the step does.
const PLUMBING = /(^|\s)(\d*>&\d+|&>\/dev\/null|\d*>>?\s*\/dev\/null|<\s*\/dev\/null)(?=\s|$)/g;

export function stepTextHtml(text) {
  let out = "";
  let at = 0;
  for (const m of String(text).matchAll(PLUMBING)) {
    const start = m.index + m[1].length;
    out += `${escapeHtml(text.slice(at, start))}<span class="step-plumbing">${escapeHtml(m[2])}</span>`;
    at = start + m[2].length;
  }
  return out + escapeHtml(String(text).slice(at));
}

// The steps as a list: a label as a small heading above its step, the op
// that links a step to the one before, its text, its limit and heredoc
// as chips (beside the text, below it when the row is narrow).
export function stepsHtml(steps) {
  const items = steps.map((step) => {
    const label = step.label ? `<li class="step-label">${escapeHtml(step.label)}</li>` : "";
    const limit = step.limit ? `<span class="step-chip" title="output limited">${escapeHtml(step.limit)}</span>` : "";
    const heredoc = step.heredoc
      ? `<span class="step-chip heredoc" title="a heredoc: its text in the raw command">${escapeHtml(step.heredoc.tag)} · ` +
        `${Number(step.heredoc.lines)} ${step.heredoc.lines === 1 ? "line" : "lines"}</span>`
      : "";
    return `${label}<li class="activity-step">${opHtml(step.op)}<span class="step-body"><code>${stepTextHtml(step.text)}</code>${limit}${heredoc}</span></li>`;
  });
  return `<ol class="activity-steps">${items.join("")}</ol>`;
}
