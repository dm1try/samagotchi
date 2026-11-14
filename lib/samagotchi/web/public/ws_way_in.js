// A tool row's way into the working set's reader (ws_reader.js): a small
// "timeline" button on an ok read, edit, write, memory_read or memory_write
// row (the item it touched: working_set.js rowEntries), which the reader's
// delegated click opens. Off until the page turns it on (app.js, for an
// owner with the working set): a participant's rows never get it (the
// null-control idiom: not drawn, not wired). turn_html.js draws it.

import { html, nothing } from "./vendor/lit-html.js";
import { rowEntries } from "./working_set.js";

const TOOLS = new Set(["read", "edit", "write", "memory_read", "memory_write"]);
let on = false;

// The page has a reader: rows drawn from now on carry the button.
export function setTimelineWayIn(value) {
  on = !!value;
}

// The button for +row+ (activity.js's row model), or nothing.
export function wayInTemplate(row) {
  if (!on || !TOOLS.has(row?.tool)) return nothing;
  const entry = rowEntries(row)[0];
  if (!entry) return nothing;
  return html`<button type="button" class="activity-ws" data-ws-kind=${entry.kind} data-ws-key=${entry.key} title="What chi has of it: open its timeline">timeline</button>`;
}
