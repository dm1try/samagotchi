// The working set popover's peek (scene C of the working-set preview): a
// row's ▸ opens, under the row, what chi has of the item now: its latest
// edit's diff (diff_view.js), else its newest read's first lines
// (ws_timeline.js peekOf), with "Open the timeline · N reads, M edits"
// (the reader, ws_reader.js) and "go to the call" (the popover's step jump).
// One row at a time. The owner's only: working_set_view.js gets none for a
// participant (the null-control idiom) and draws today's rows.
//
// The item's timeline comes from the item route (+getItem+); an answer for
// a row no longer open, or another session, is dropped (latest.js). While a
// row is open, each new server snapshot asks again (refresh): the route
// builds from the session's messages, which lag a running turn.

import { html, nothing } from "./vendor/lit-html.js";
import { createLatest } from "./latest.js";
import { diffCounts, diffTemplate } from "./diff_view.js";
import { callTemplate, linesTemplate, textTemplate } from "./ws_cards.js";
import { countsText, eventTag, eventWords, peekOf } from "./ws_timeline.js";

// The popover's width while a row is peeked (it is 420 otherwise).
export const PEEK_WIDTH = 520;

// +session()+: the open session's id; +getItem(id, kind, key)+: the item
// route's answer; +onChange()+: the peek's content changed (the popover
// redraws and places itself again).
export function createPeek({ session, getItem, onChange = () => {} }) {
  let openId = null;
  let item = null;
  let data = null;
  let failed = false;
  const latest = createLatest(() => `${session()}|${openId}`);

  function load() {
    const id = session();
    if (!id || !item) return;
    const fresh = latest.begin();
    const { kind, key } = item;
    Promise.resolve()
      .then(() => getItem(id, kind, key))
      .then((answer) => {
        if (!fresh()) return;
        data = answer;
        failed = false;
        onChange();
      })
      .catch(() => {
        if (!fresh()) return;
        failed = true;
        onChange();
      });
  }

  function close() {
    openId = null;
    item = null;
    data = null;
    failed = false;
    latest.drop();
  }

  return {
    // +id+'s row (working_set.js steerId) opened, or closed when it was.
    toggle(id, row) {
      if (openId === id) close();
      else {
        openId = id;
        item = row;
        data = null;
        failed = false;
        load();
      }
      onChange();
    },
    isOpen: (id) => openId === id,
    any: () => openId !== null,
    close,
    // A new server snapshot: the open row's timeline asked again (its
    // drawn one stays until the answer).
    refresh(row = item) {
      if (!openId) return;
      item = row || item;
      load();
    },
    // The peek under +row+ (the row's item, overlaid: its runs for the
    // step tags).
    template(row) {
      if (failed) return html`<div class="ws-peek" role="region" aria-label="What chi has"><div class="ws-peek-note">Couldn't load what chi has of it.</div></div>`;
      if (!data) return html`<div class="ws-peek" role="region" aria-label="What chi has"><div class="ws-peek-note">Loading…</div></div>`;
      const events = data.events || [];
      const peek = peekOf(events);
      if (!peek) return html`<div class="ws-peek" role="region" aria-label="What chi has"><div class="ws-peek-note">Nothing of it in the conversation yet.</div></div>`;
      const { event } = peek;
      const counts = peek.kind === "diff" && event.diff?.text && !event.diff.error && !event.diff.skipped ? diffCounts(event.diff) : "";
      const after = peek.after ? html`<span class="ws-peek-after">then ${eventWords(peek.after)} at ${eventTag(peek.after, row)}</span>` : nothing;
      const gone = event.sent === false ? html`<span class="wsr-pill gone">chi no longer has this</span>` : nothing;
      const head = html`<div class="ws-peek-h"><span class="ws-peek-t">latest · ${eventWords(event)} at ${eventTag(event, row)}</span>${counts ? html`<span class="ws-peek-c">${counts}</span>` : nothing}${gone}${after}</div>`;
      let body;
      if (peek.kind === "diff") body = diffTemplate(event.diff, { fold: 12 });
      else if (peek.kind === "lines") body = linesTemplate(peek.rows, { fold: Infinity });
      else body = textTemplate(peek.rows.map((r) => r.text).join("\n"), { fold: Infinity });
      const words = countsText(events);
      const foot = html`<div class="ws-peek-f"><button type="button" class="ws-peek-open" data-ws="timeline" data-ws-id=${openId}>Open the timeline${words ? html`<span class="ws-peek-n"> · ${words}</span>` : nothing}</button>${callTemplate(event, row)}</div>`;
      return html`<div class="ws-peek" role="region" aria-label="What chi has">${head}<div class="ws-peek-b">${body}</div>${foot}</div>`;
    },
  };
}
