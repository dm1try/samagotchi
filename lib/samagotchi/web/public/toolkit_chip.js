// The session bar's 🧰 chip, after ⚙: the session's toolkit. "🧰" alone
// while the session is on config's default kit (toolkit.default, full
// unless set; GET /api/sessions/:id's session.toolkit_default), "🧰 lean"
// on another; the tooltip names the kit, the tools it leaves out and how to
// change them. No popover: /toolkit changes it. The summary is the
// session's toolkit ({name, label, left_out, reachable, removed, fallback}:
// Toolkit::Explained#summary, null on full; the worker's snapshot or a
// command_ran; the server's own reading of the session file has no lists).
// Left out is reachable (find_tools and call_tool reach them) and removed
// (only /toolkit add brings one back). A kit with a prompt text has it on
// the summary too (prompt), and the tooltip ends with it.

import { html, nothing } from "./vendor/lit-html.js";

const FULL = "full";
const CHANGE = "/toolkit lists them; /toolkit NAME, add TOOL or remove TOOL changes them from the next turn.";

// The chip's text ("" while on the default kit: 🧰 alone), tooltip and
// whether it is the default. +summary+: the session's (null: full);
// +defaultKit+: config's toolkit.default (null: not known, full).
export function chipModel(summary, defaultKit = null) {
  const fallbackKit = defaultKit || FULL;
  if (!summary) {
    const isDefault = fallbackKit === FULL;
    const title = isDefault ? `Toolkit: ${FULL} (the default), every tool is declared. ${CHANGE}`
      : `Toolkit: ${FULL}, every tool is declared (the default is ${fallbackKit}). ${CHANGE}`;
    return { text: isDefault ? "" : FULL, title, isDefault };
  }
  const label = summary.label || summary.name;
  const isDefault = !summary.fallback && label === fallbackKit;
  const parts = [`Toolkit: ${label}${isDefault ? " (the default)" : ""}, the tools this session declares.`];
  if (summary.fallback) parts.push(`${summary.fallback}: every tool is declared (full) until it resolves.`);
  if (Array.isArray(summary.groups)) {
    parts.push(`Source groups: ${summary.groups.length ? summary.groups.join(", ") : "none"}.`);
  }
  const reachable = Array.isArray(summary.reachable) ? summary.reachable : [];
  const removed = Array.isArray(summary.removed) ? summary.removed : [];
  if (reachable.length) {
    parts.push(`Reachable with find_tools: ${reachable.join(", ")}.`);
    if (removed.length) parts.push(`Removed: ${removed.join(", ")}.`);
  } else if (Array.isArray(summary.left_out)) {
    parts.push(summary.left_out.length ? `Not loaded: ${summary.left_out.join(", ")}.` : "Nothing left out.");
  }
  parts.push(CHANGE);
  if (summary.prompt) parts.push(`Prompt: ${summary.prompt}`);
  return { text: isDefault ? "" : `${label}${summary.fallback ? " ?" : ""}`, title: parts.join(" "), isDefault };
}

// The session bar's chip (a lit-html template; info_bar.js): +toolkit+ is
// {summary, defaultKit}; nothing without it. 🧰 is drawn as the start
// page's toolkit icon (the glyph stays the text; index.html's CSS).
export function chipTemplate(toolkit) {
  if (!toolkit) return nothing;
  const chip = chipModel(toolkit.summary, toolkit.defaultKit);
  return html`<span class=${`model tools-chip${chip.isDefault ? " default" : ""}`} title=${chip.title}><span
    class="chip-icon tc-kit" aria-hidden="true">🧰</span>${chip.text ? ` ${chip.text}` : ""}</span>`;
}
