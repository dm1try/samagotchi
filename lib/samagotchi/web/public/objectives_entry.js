// An objectives note in the conversation, in place of the plain note bubble
// (turn_html.js noteBubbleTemplate): the list as pills, or, for a later edit, one
// line saying what the user changed. Read-only: the strip above the history is
// where the list is edited (objectives_strip.js). The raw note text stays the
// tooltip. A module of its own: static JS is cached at unversioned URLs.
import { html, nothing } from "./vendor/lit-html.js";
import { DROPPED, entryLine } from "./objectives_model.js";

function pill(item) {
  const klass = `obj-pill ${item.status}`;
  return html`<span class=${klass} title=${item.done_when ? `done when: ${item.done_when}` : nothing}><span class="obj-id">${item.id}</span> ${item.status === "done" ? "✓ " : ""}${item.text}</span>`;
}

export function objectivesEntryTemplate(note, timeTitle = "") {
  const line = entryLine(note.objectives);
  const tip = [timeTitle, note.content].filter(Boolean).join("\n");
  if (line) {
    return html`<div class="bubble note objectives-entry change" title=${tip}><span class="obj-rule" aria-hidden="true"></span><span class="obj-change">${line}</span><span class="obj-rule" aria-hidden="true"></span></div>`;
  }
  const items = (note.objectives?.items || []).filter((i) => i.status !== DROPPED);
  return html`<div class="bubble note objectives-entry" title=${tip}><span class="obj-entry-label">Objectives</span>${items.map(pill)}</div>`;
}
