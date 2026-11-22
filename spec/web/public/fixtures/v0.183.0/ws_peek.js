// The working set popover's peek (scene C of the working-set preview): a
// row's ▸ opens, under the row, what chi has of the item now: its latest
// edit's diff (diff_view.js), else its newest read's first lines
// (ws_timeline.js peekOf), with "Open the timeline · N reads, M edits"
// (the reader, ws_reader.js) and "go to the call" (the popover's step jump).
// One row at a time. The owner's only: working_set_view.js gets none for a
// participant (the null-control idiom) and draws today's rows.
//
// The item's peek comes from the item route (+getItem+, latest: only the
// events peekOf picks and the counts; an older worker's whole timeline
// draws the same); an answer for a row no longer open, or another session,
// is dropped (latest.js), and so is one older than the drawn one within a
// running turn (olderAnswer). While a row is open, a new server snapshot
// asks again (refresh) only when the item's server signature changed
// (+sigOf+: working_set.js serverSig): mid-turn the route answers the
// running turn's view as of its last step.
//
// A memory's text and a whole read of an .md file show rendered, the whole
// text in the peek's scroll box, once their HTML is in the reader's cache
// (+md+: ws_markdown.js createRenderCache); else, and without +md+, the
// first lines as source.

import { html, nothing } from "./vendor/lit-html.js";
import { createLatest } from "./latest.js";
import { diffCounts, diffTemplate } from "./diff_view.js";
import { callTemplate, linesTemplate, textTemplate } from "./ws_cards.js";
import { countsText, eventTag, eventWords, peekOf } from "./ws_timeline.js";
import { olderAnswer } from "./ws_item_sig.js";
import { peekMarkdownTemplate, peekText, renderableEvent } from "./ws_markdown.js";

// No events while a turn runs (the answer's +running+): the read is in the
// step whose tool batch hasn't ended.
const STEP_RUNNING = "chi read this in the step still running. It shows here when that step's tools finish.";

// The popover's width while a row is peeked (it is 420 otherwise).
export const PEEK_WIDTH = 520;

// +session()+: the open session's id; +getItem(id, kind, key, opts)+: the item
// route's answer; +sigOf(item)+: its server signature (undefined: always ask
// again); +onChange()+: the peek's content changed (the popover redraws and
// places itself again); +md+: the reader's markdown cache ({html(text)}),
// null: none.
export function createPeek({ session, getItem, sigOf = () => undefined, onChange = () => {}, md = null }) {
  let openId = null;
  let item = null;
  let data = null;
  let failed = false;
  let askedSig;
  const latest = createLatest(() => `${session()}|${openId}`);

  function load() {
    const id = session();
    if (!id || !item) return;
    const fresh = latest.begin();
    const { kind, key } = item;
    askedSig = sigOf(item);
    Promise.resolve()
      .then(() => getItem(id, kind, key, { latest: true }))
      .then((answer) => {
        if (!fresh() || olderAnswer(data, answer)) return;
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
    // A new server snapshot: the open row's timeline asked again when its
    // server signature changed (its drawn one stays until the answer).
    refresh(row = item) {
      if (!openId) return;
      item = row || item;
      const sig = sigOf(item);
      if (!failed && sig !== undefined && sig === askedSig) return;
      load();
    },
    // The peek under +row+ (the row's item, overlaid: its runs for the
    // step tags).
    template(row) {
      if (failed) return html`<div class="ws-peek" role="region" aria-label="What chi has"><div class="ws-peek-note">Couldn't load what chi has of it.</div></div>`;
      if (!data) return html`<div class="ws-peek" role="region" aria-label="What chi has"><div class="ws-peek-note">Loading…</div></div>`;
      const events = data.events || [];
      const peek = peekOf(events);
      if (!peek) return html`<div class="ws-peek" role="region" aria-label="What chi has"><div class="ws-peek-note">${data.running ? STEP_RUNNING : "Nothing of it in the conversation yet."}</div></div>`;
      const { event } = peek;
      const counts = peek.kind === "diff" && event.diff?.text && !event.diff.error && !event.diff.skipped ? diffCounts(event.diff) : "";
      const after = peek.after ? html`<span class="ws-peek-after">then ${eventWords(peek.after)} at ${eventTag(peek.after, row)}</span>` : nothing;
      const gone = event.sent === false ? html`<span class="wsr-pill gone">chi no longer has this</span>` : nothing;
      const head = html`<div class="ws-peek-h"><span class="ws-peek-t">latest · ${eventWords(event)} at ${eventTag(event, row)}</span>${counts ? html`<span class="ws-peek-c">${counts}</span>` : nothing}${gone}${after}</div>`;
      let body;
      const markdown = peek.kind !== "diff" && renderableEvent(event, row);
      const rendered = md && markdown ? peekMarkdownTemplate(event.text, md) : null;
      if (rendered) body = rendered;
      else if (peek.kind === "diff") body = diffTemplate(event.diff, { fold: 12 });
      else if (peek.kind === "lines") body = linesTemplate(peek.rows, { fold: Infinity });
      else {
        const text = peek.rows.map((r) => r.text).join("\n");
        body = textTemplate(markdown ? peekText(text) : text, { fold: Infinity });
      }
      const words = countsText(events, data.counts);
      const foot = html`<div class="ws-peek-f"><button type="button" class="ws-peek-open" data-ws="timeline" data-ws-id=${openId}>Open the timeline${words ? html`<span class="ws-peek-n"> · ${words}</span>` : nothing}</button>${callTemplate(event, row)}</div>`;
      return html`<div class="ws-peek" role="region" aria-label="What chi has">${head}<div class="ws-peek-b">${body}</div>${foot}</div>`;
    },
  };
}
