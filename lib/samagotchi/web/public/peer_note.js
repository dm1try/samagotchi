// A peer's answer in the conversation (turn_html.js noteBubbleTemplate
// draws a note with `peer` here): a bubble from the peer, its verdict and
// summary, and chi's instruction to the model folded behind "what chi told
// the agent". It keeps what a note that opens a wake turn carries (the
// classes `bubble note` and `turn-start`, data-opening-id, the time title):
// TURN_PROMPT (bubbles.js), card_stamps.js, stage_handoff.js OPENING,
// reload_check.js and revise_stack.js (its `.note-text`, the summary) read
// it as any wake note. The ↑ to the send and "Read the full answer" are
// slots peer_links.js fills (data-peer-slot: history_shape.js leaves them
// out, so live and an offscreen reload read alike). A note whose peer hash
// says `inline` holds the peer's text (peer_text.js): the bubble shows it
// in `.peer-text` under the summary, as plain text that peer_links.js
// swaps for its markdown (its source kept in data-peer-md), the fold shows
// the rest, and the bubble is marked data-peer-inline (no "Read the full
// answer").
// Its own module: new exports go in new modules (web-frontend.md).

import { html, nothing } from "./vendor/lit-html.js";
import { fullTime } from "./format.js";
import { peerBlock } from "./peer_text.js";

const VERDICT_CLASS = { OK: "ok", CHANGES: "changes", UNSURE: "unsure" };

// The answer's verdict pill (the note's peer.verdict, the server's word):
// "VERDICT OK" with "round closed" when the peer agreed, CHANGES, UNSURE;
// nothing for none. The phone shows the bare word (CSS).
export function verdictTemplate(peer) {
  const kind = VERDICT_CLASS[peer?.verdict];
  if (!kind) return nothing;
  const closed = peer.agreed && peer.verdict === "OK"
    ? html`<span class="peer-closed">round closed</span>` : nothing;
  return html`<span class="peer-mark">${closed}<span class=${`peer-verdict ${kind}`}><span class="peer-long">VERDICT </span>${peer.verdict}</span></span>`;
}

// What the bubble says the peer answered: its summary, else the note's
// first line that says something (a quote's `> ` dropped), else "(no
// summary)". revise_stack.js labels a Revise version with it.
export function peerSummaryText(note) {
  const summary = String(note?.peer?.summary ?? "").trim();
  if (summary) return summary;
  const line = String(note?.content ?? "").split("\n").map((l) => l.replace(/^\s*>\s?/, "").trim()).find(Boolean);
  return line || "(no summary)";
}

// The bubble for +note+ (a context note with `peer`: {peer, label, re,
// summary, serial, verdict, agreed, inline}).
export function peerNoteTemplate(note) {
  const peer = note.peer || {};
  const name = peer.label || peer.peer || "Your peer";
  const cls = note.turn_start ? "bubble note turn-start peer-answer" : "bubble note peer-answer";
  const opening = note.turn_start && note.turn_id ? String(note.turn_id) : nothing;
  const source = note.context_source || (peer.peer ? `${peer.peer}-outbox` : "");
  const attr = (value) => (value === null || value === undefined || value === "" ? nothing : String(value));
  const block = peer.inline ? peerBlock(note.content) : null;
  const body = block ? html`<div class="peer-text" data-peer-md=${block.text}>${block.text}</div>` : nothing;
  const told = block ? block.rest : (note.content ?? "");
  return html`<div class=${cls} title=${fullTime(note.at) || nothing} data-opening-id=${opening} data-peer-source=${attr(source)} data-peer-name=${attr(peer.peer)} data-peer-re=${attr(peer.re)} data-peer-serial=${attr(peer.serial)} data-peer-inline=${block ? "1" : nothing}><div class="peer-head"><span class="peer-who">${name} answered</span><span class="peer-up-slot" data-peer-slot="up"></span>${verdictTemplate(peer)}</div><div class="note-text">${peerSummaryText(note)}</div>${body}<div class="peer-foot"><span class="peer-full-slot" data-peer-slot="full"></span><details class="peer-told"><summary>what chi told the agent</summary><div class="peer-told-text">${told}</div></details></div></div>`;
}
