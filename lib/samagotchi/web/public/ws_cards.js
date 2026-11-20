// The timeline's cards as lit templates (ws_timeline.js makes them): the
// reader's (ws_reader.js) and the popover peek's (ws_peek.js) one look. A
// read's lines draw as a read row's do (.read-line, numbered); an edit's
// diff with diff_view.js, the same renderer as the tool row's and the
// approval card's. A card chi no longer has is greyed, its text folded.
// A memory's text and a whole read of an .md file render as markdown once
// their HTML is there (ws_markdown.js; the +md+ option), with a
// "rendered | source" switch in the card's header.

import { html, nothing } from "./vendor/lit-html.js";
import { diffCounts, diffTemplate } from "./diff_view.js";
import { eventTag, goneText, linesText, placeOf, SLICE_FOLD_LINES, tagsText } from "./ws_timeline.js";
import { markdownTemplate, renderable, sourceText } from "./ws_markdown.js";

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

// Numbered lines (+rows+ [{n, text}]); past +fold+ the rest behind a
// "show all" toggle (lit never binds its open).
export function linesTemplate(rows, { fold = SLICE_FOLD_LINES } = {}) {
  const span = ({ n, text }) => html`<span class="read-line" data-line=${n}>${text || html`<br>`}</span>`;
  const head = html`<pre class="read-lines wsr-lines"><code>${rows.slice(0, fold).map(span)}</code></pre>`;
  if (rows.length <= fold) return head;
  return html`${head}<details class="diff-more"><summary>show all ${rows.length} lines</summary><pre class="read-lines wsr-lines"><code>${rows.slice(fold).map(span)}</code></pre></details>`;
}

// A text as it was sent (a memory's, a fetch's, a partial read's), wrapped.
export function textTemplate(text, { fold = SLICE_FOLD_LINES } = {}) {
  const lines = String(text ?? "").split("\n");
  if (lines.length <= fold) return html`<pre class="wsr-text">${text}</pre>`;
  return html`<pre class="wsr-text">${lines.slice(0, fold).join("\n")}</pre><details class="diff-more"><summary>show all ${lines.length} lines</summary><pre class="wsr-text">${lines.slice(fold).join("\n")}</pre></details>`;
}

// "go to the call": the event's row (+item+'s runs), none when it isn't
// drawn.
export function callTemplate(event, item, label = "go to the call") {
  const at = placeOf(event, item);
  if (!at) return nothing;
  return html`<button type="button" class="wsr-call" data-ws="jump" data-at=${`${at.turn}.${at.step}.${at.row}`}>${label}</button>`;
}

// The card's "rendered | source" switch (+view+ the one pressed).
function viewTemplate(view) {
  const button = (name) => html`<button type="button" class=${view === name ? "on" : ""} aria-pressed=${String(view === name)} data-wsr="view" data-view=${name}>${name}</button>`;
  return html`<span class="wsr-view" role="group" aria-label="Show as">${button("rendered")}${button("source")}</span>`;
}

// A text, rendered when +shown+ holds its markdown (else as sent).
const textOr = (text, shown) => shown ?? textTemplate(text);

function goneBody(card, rows, undrop, shown = null) {
  const words = goneText(card.state);
  const what = card.type === "slice" ? plural(rows.length, "line") : "its text";
  const offer = card.state === "dropped" && undrop !== nothing ? html` · ${undrop}` : nothing;
  const had = shown ?? (card.type === "slice" ? linesTemplate(rows) : textTemplate(card.event.text));
  return html`<div class="wsr-gone">${what} · ${words}${offer}</div><details class="wsr-had"><summary>what it was</summary>${had}</details>`;
}

// A memory read's overlay part (ws_timeline: event.memory.overlay),
// rendered with its card (+md+, +on+: the card shows rendered).
function overlayTemplate(memory, md = null, on = false) {
  if (!memory?.overlay) return nothing;
  const name = String(memory.overlay_path || "").split("/").pop();
  // Asked with its card's text, so both come together.
  const rendered = md ? markdownTemplate(memory.overlay, md) : null;
  const shown = on ? rendered : null;
  return html`<div class="wsr-overlay"><div class="wsr-overlay-h">+ overlay for this model${name ? ` · ${name}` : ""}</div>${textOr(memory.overlay, shown)}</div>`;
}

// One card. +item+: the open item (its runs: the step tags); +undrop+: the
// greyed card's undrop button (a template), or nothing; +md+ ({view,
// html(text)}: the reader's): a renderable card whose HTML is there gets
// the switch and, with +view+ "rendered", its markdown. Without it (an old
// reader), today's source.
export function cardTemplate(card, { item, undrop = nothing, md = null } = {}) {
  const gone = card.state && card.state !== "sent";
  const pill = gone ? html`<span class="wsr-pill gone">chi no longer has this</span>`
    : card.latest ? html`<span class="wsr-pill latest">latest</span>` : nothing;
  let title;
  let meta = "";
  let body;
  let call;
  const rendered = md && renderable(card, item) ? markdownTemplate(sourceText(card), md) : null;
  const on = rendered !== null && md.view !== "source";
  const shown = on ? rendered : null;
  if (card.type === "slice") {
    title = linesText(card);
    meta = `${plural(card.reads.length, "read")} · ${tagsText(card.reads, item)}`;
    body = gone ? goneBody(card, card.rows, undrop, shown) : shown ?? linesTemplate(card.rows);
    call = callTemplate(card.reads[0], item);
  } else {
    const { event } = card;
    const tag = eventTag(event, item);
    call = callTemplate(event, item);
    if (card.type === "edit") {
      title = `${event.op} · ${tag}`;
      const diff = event.diff;
      meta = diff && !diff.error && !diff.skipped && diff.text ? diffCounts(diff) : "";
      body = diff ? diffTemplate(diff) : html`<div class="diff-note">no diff saved (no change, or the file couldn't be read)</div>`;
    } else if (card.type === "partial") {
      title = `${linesText(event.lines)} · ${tag}`;
      meta = "shown as chi got it";
      body = gone ? goneBody(card, [], undrop) : textTemplate(event.text);
    } else {
      const words = { memory: "read", written: "memory write", fetch: "fetch" }[card.type];
      title = `${words} · ${tag}`;
      const shared = event.shared_with?.length ? `read with ${event.shared_with.join(", ")}` : "";
      meta = shared;
      body = gone ? goneBody(card, [], undrop, shown) : html`${textOr(event.text, shown)}${card.type === "memory" ? overlayTemplate(event.memory, md, on) : nothing}`;
    }
  }
  const classes = `wsr-card ${card.type}${gone ? ` gone ${card.state}` : ""}${card.latest ? " latest" : ""}`;
  const view = rendered !== null ? viewTemplate(on ? "rendered" : "source") : nothing;
  const first = card.type === "slice" ? card.first : nothing;
  return html`<article class=${classes} data-newest=${card.newest} data-first=${first}><header class="wsr-card-h"><span class="wsr-card-t">${title}</span>${meta ? html`<span class="wsr-card-m">${meta}</span>` : nothing}${pill}${view}${call}</header>${body}</article>`;
}
