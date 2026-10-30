// The session bar's info line (#infoText): the open session's id (a button
// that copies the full id), status, model, chain links, parent and delegates,
// thinking, reasoning history, llm ctx and tools chips, model notes, memories, folder, ctx, speed,
// session clock and the worker's version badge. A lit-html template over a
// plain model (info_bar_model.js, applied by app.js's updateInfoBar), so the markup lives here and
// runs under node --test (spec/web/public/info_bar.test.js).
//
// It is redrawn every second while a turn runs (the session clock): lit
// writes only what changed, so a shown tooltip stays up, a press on one of
// its buttons isn't lost to a rewrite, and the chips' popovers keep their
// anchor (clicks on it are delegated, app.js and the chip controls).

import { html, nothing, render } from "./vendor/lit-html.js";
import { memChipText, memChipTitle } from "./format.js";
import { ALL_SESSIONS_HASH, sessionHash } from "./route.js";
import { chipTemplate as llmContextChip } from "./llm_context_chip.js";
import { chipTemplate as thinkingChip } from "./thinking_chip.js";
import { chipTemplate as reasoningHistoryChip } from "./reasoning_history_chip.js";
import { chipTemplate as toolkitChip } from "./toolkit_chip.js";
import { chipTemplate as participantsChip } from "./participants_panel.js";

export const PREV = "←";
// The session clock's placeholder before its first turn: the chip shows
// from the start, so the first turn doesn't add it to the line.
export const CLOCK_NONE = "session –";
export const NEXT = "→";

// A chain's ← / → link (chains.js chainNeighbours): its date or time (else
// its short id), its id, full start and preview in the tooltip. +link+:
// {id, date, stamp, preview, archived} (info_bar_model.js chainLinkView).
export function chainLinkTemplate(link, arrow, what) {
  const short = String(link.id).slice(0, 8);
  const title = `${what}: ${short}${link.stamp ? ` · ${link.stamp}` : ""}${link.preview ? ` · ${link.preview}` : ""}${link.archived ? " (archived)" : ""}`;
  const text = arrow === PREV ? `${arrow} ${link.date || short}` : `${link.date || short} ${arrow}`;
  return html`<a class="model chain-link" href=${sessionHash(link.id)} title=${title}>${text}</a>`;
}

// `memories: a, b · preloaded: c · muted: d`: the used memories always,
// the session's --memory and --mute lists only when there are any.
export function memoriesTooltip(used, preloaded, muted) {
  const parts = [`memories: ${(used || []).join(", ") || "—"}`];
  if (preloaded && preloaded.length) parts.push(`preloaded: ${preloaded.join(", ")}`);
  if (muted && muted.length) parts.push(`muted: ${muted.join(", ")}`);
  return parts.join(" · ");
}

// The open session's worker runs an older chi than the newest installed
// (update_notice.js workerBadge): its badge, with Restart when it can.
function workerBadgeTemplate(worker) {
  if (!worker?.badge) return nothing;
  const { badge, busy } = worker;
  const button = badge.restart
    ? html`<button type="button" class="worker-restart" ?disabled=${busy}>${busy ? "restarting…" : "Restart"}</button>`
    : nothing;
  return html`<span class="worker-badge" title=${badge.title}>${badge.text}${button}</span>`;
}

function kidsTemplate(kids) {
  if (!kids) return nothing;
  const waiting = kids.waitingText ? html` · <span class="kids-waiting">${kids.waitingText}</span>` : nothing;
  return html`<a class=${`model children-chip${kids.waitingText ? " waiting" : ""}`} href=${ALL_SESSIONS_HASH} title=${`${kids.title} (all sessions)`}>${kids.text}${waiting}</a>`;
}

// The working set's chip (web.working_set), in the mem chip's place: a dot
// (the accent when the set changed since its list was last opened) and
// "set N". It shows from the session's start, "set 0" muted while the set
// is empty, so the turn's first read doesn't widen the line (a wider line
// can wrap the folder onto the next row and move the stage).
// +chip+: {n, changed}.
export function workingSetChipTemplate(chip) {
  if (!chip) return nothing;
  const what = chip.n ? `${chip.n} item${chip.n === 1 ? "" : "s"} this session brought into context` : "nothing this session brought into context yet";
  const title = `Working set: ${what} (files, memories, URLs)${chip.changed ? ", changed since you last looked" : ""}. Open the list.`;
  const cls = `model ws-chip${chip.changed ? " changed" : ""}${chip.n ? "" : " empty"}`;
  return html`<button type="button" class=${cls} title=${title} aria-label=${title} aria-haspopup="dialog"><span class="ws-dot" aria-hidden="true"></span>set ${chip.n}</button>`;
}

// The info line for +bar+, nothing without a session (the start page hides
// the bar). +bar+:
//   id, status, model ({text, title,
//   mismatch}: format.js modelLabel), chain ({prev, next}: chainLinkTemplate's
//   links or null), parent ({id, title} or null), kids (format.js
//   childrenSummary), llmContext, thinking and reasoningHistory (the chips'
//   summaries; reasoningHistory null on a native host: no chip), toolkit
//   (the tools chip's summary, null on full: no chip), notes
//   ({text, title} or null), memories (the used names), workingSet
//   (web.working_set on: {chip}, the working set's chip in place of the
//   mem chip; null: off), dir, ctx ({text,
//   tip}), speed ({text, tip, empty}: empty, a muted placeholder before the
//   first generation; null: no chip), clock (the session time's text, "" for
//   none: the muted CLOCK_NONE), worker ({badge, busy} or null), participants (the
//   participants chip: participants_panel.js chipModel, or null).
export function infoBarHtml(bar) {
  if (!bar) return nothing;
  const memories = bar.memories || [];
  return html`<div class="meta"><button type="button" class="id" title=${`Session id ${bar.id}: click to copy it`}>${String(bar.id).slice(0, 8)}</button><span class=${bar.status ? `status ${bar.status}` : "status"}><span>${bar.status || ""}</span></span><span class=${`model${bar.model.mismatch ? " served-mismatch" : ""}`} title=${bar.model.title}>${bar.model.text}</span>${bar.chain?.prev ? chainLinkTemplate(bar.chain.prev, PREV, "The previous link of this chain") : nothing}${bar.chain?.next ? chainLinkTemplate(bar.chain.next, NEXT, "The next link of this chain") : nothing}${bar.parent ? html`<a class="model parent" href=${sessionHash(bar.parent.id)} title=${bar.parent.title}>delegated by ${String(bar.parent.id).slice(0, 8)}</a>` : nothing}${kidsTemplate(bar.kids)}${thinkingChip(bar.thinking)}${reasoningHistoryChip(bar.reasoningHistory)}${llmContextChip(bar.llmContext)}${toolkitChip(bar.toolkit)}${participantsChip(bar.participants)}${bar.notes ? html`<span class="model notes-chip" title=${bar.notes.title}>${bar.notes.text}</span>` : nothing}${bar.workingSet ? workingSetChipTemplate(bar.workingSet.chip) : memories.length ? html`<span class="model mem-chip" title=${memChipTitle(memories)}>${memChipText(memories)}</span>` : nothing}<span class="dir" title=${bar.dir || ""}><bdi>${bar.dir || ""}</bdi></span><span class="model ctx" title=${bar.ctx.tip}>${bar.ctx.text}</span>${bar.speed ? html`<span class=${`model speed${bar.speed.empty ? " empty" : ""}`} title=${bar.speed.tip}>${bar.speed.text}</span>` : nothing}<span class=${`model session-time${bar.clock ? "" : " empty"}`} title=${bar.clock ? "This session's time: its turns, and the running one" : "This session's time: no turn yet"}>${bar.clock || CLOCK_NONE}</span>${workerBadgeTemplate(bar.worker)}</div>`;
}

// Draws +bar+ into +el+ (#infoText), with the memories in its tooltip
// (with the working set on, its list says them instead).
export function renderInfoBar(el, bar) {
  render(infoBarHtml(bar), el);
  el.title = bar && !bar.workingSet ? memoriesTooltip(bar.memories, bar.preloaded, bar.muted) : "";
}
