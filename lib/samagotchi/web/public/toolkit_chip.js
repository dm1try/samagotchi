// The session bar's tools chip: the session's toolkit when it isn't full
// ("tools lean"), with the tools it leaves out and how to change them in
// its tooltip. The summary is the session's toolkit ({name, label,
// left_out, reachable, removed, fallback}: Toolkit::Explained#summary; the
// worker's snapshot or a command_ran; the server's own reading of the
// session file has no lists). Left out is reachable (find_tools and
// call_tool reach them) and removed (only /toolkit add brings one back).
// Changing it is /toolkit (no popover yet).

import { html, nothing } from "./vendor/lit-html.js";

// The chip's text and tooltip; null without a summary (full).
export function chipModel(summary) {
  if (!summary) return null;
  const label = summary.label || summary.name;
  const parts = [`Toolkit: ${label}, the tools this session declares.`];
  if (summary.fallback) parts.push(`${summary.fallback}: every tool is declared (full) until it resolves.`);
  const reachable = Array.isArray(summary.reachable) ? summary.reachable : [];
  const removed = Array.isArray(summary.removed) ? summary.removed : [];
  if (reachable.length) {
    parts.push(`Reachable with find_tools: ${reachable.join(", ")}.`);
    if (removed.length) parts.push(`Removed: ${removed.join(", ")}.`);
  } else if (Array.isArray(summary.left_out)) {
    parts.push(summary.left_out.length ? `Not loaded: ${summary.left_out.join(", ")}.` : "Nothing left out.");
  }
  parts.push("/toolkit lists them; /toolkit NAME, add TOOL or remove TOOL changes them from the next turn.");
  return { text: `tools ${label}${summary.fallback ? " ?" : ""}`, title: parts.join(" ") };
}

// The session bar's chip (a lit-html template; info_bar.js), nothing on
// full.
export function chipTemplate(summary) {
  const chip = chipModel(summary);
  if (!chip) return nothing;
  return html`<span class="model tools-chip" title=${chip.title}>${chip.text}</span>`;
}
