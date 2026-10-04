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
export function commandBlockHtml(view) {
  const command = view?.command;
  if (!command) return "";
  const cwd = view.cwd ? `<div class="activity-command-cwd">in <span>${escapeHtml(view.cwd)}</span></div>` : "";
  const cut = view.truncated
    ? `<div class="activity-command-cut">… (${command.length.toLocaleString("en-US")} of ${Number(view.chars || 0).toLocaleString("en-US")} chars)</div>`
    : "";
  return `<div class="activity-command code-wrap">${cwd}<pre><code>${escapeHtml(command)}</code></pre>${copyButtonHtml("code")}${cut}</div>`;
}
