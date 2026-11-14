// The timeline's cards as lit templates (ws_timeline.js makes them): the
// reader's (ws_reader.js) and the popover peek's (ws_peek.js) one look. A
// read's lines draw as a read row's do (.read-line, numbered); an edit's
// diff with diff_view.js, the same renderer as the tool row's and the
// approval card's. A card chi no longer has is greyed, its text folded.

import { html, nothing } from "./vendor/lit-html.js";
import { diffCounts, diffTemplate } from "./diff_view.js";
import { eventTag, goneText, linesText, placeOf, SLICE_FOLD_LINES, tagsText } from "./ws_timeline.js";

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

function goneBody(card, rows, undrop) {
  const words = goneText(card.state);
  const what = card.type === "slice" ? plural(rows.length, "line") : "its text";
  const offer = card.state === "dropped" && undrop !== nothing ? html` · ${undrop}` : nothing;
  return html`<div class="wsr-gone">${what} · ${words}${offer}</div><details class="wsr-had"><summary>what it was</summary>${card.type === "slice" ? linesTemplate(rows) : textTemplate(card.event.text)}</details>`;
}

// A memory read's overlay part (ws_timeline: event.memory.overlay).
function overlayTemplate(memory) {
  if (!memory?.overlay) return nothing;
  const name = String(memory.overlay_path || "").split("/").pop();
  return html`<div class="wsr-overlay"><div class="wsr-overlay-h">+ overlay for this model${name ? ` · ${name}` : ""}</div>${textTemplate(memory.overlay)}</div>`;
}

// One card. +item+: the open item (its runs: the step tags); +undrop+: the
// greyed card's undrop button (a template), or nothing.
export function cardTemplate(card, { item, undrop = nothing } = {}) {
  const gone = card.state && card.state !== "sent";
  const pill = gone ? html`<span class="wsr-pill gone">chi no longer has this</span>`
    : card.latest ? html`<span class="wsr-pill latest">latest</span>` : nothing;
  let title;
  let meta = "";
  let body;
  let call;
  if (card.type === "slice") {
    title = linesText(card);
    meta = `${plural(card.reads.length, "read")} · ${tagsText(card.reads, item)}`;
    body = gone ? goneBody(card, card.rows, undrop) : linesTemplate(card.rows);
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
      body = gone ? goneBody(card, [], undrop) : html`${textTemplate(event.text)}${card.type === "memory" ? overlayTemplate(event.memory) : nothing}`;
    }
  }
  const classes = `wsr-card ${card.type}${gone ? ` gone ${card.state}` : ""}${card.latest ? " latest" : ""}`;
  return html`<article class=${classes} data-newest=${card.newest}><header class="wsr-card-h"><span class="wsr-card-t">${title}</span>${meta ? html`<span class="wsr-card-m">${meta}</span>` : nothing}${pill}${call}</header>${body}</article>`;
}
