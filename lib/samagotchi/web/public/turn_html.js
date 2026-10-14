// The turn's pieces as lit-html templates, one for the live page and a
// reload: a tool row, a prompt bubble, a note, a steer, the notice of a
// turn with no answer. The live page renders the same template a reload
// does (elementOf, or its own lit root for a tool row), so the two can't
// drift apart. `node --test` covers it (on the happy-dom shim).
import { toolName } from "./activity.js";
import { html, nothing, render } from "./vendor/lit-html.js";
import { commandBlockTemplate, rowHover } from "./command_view.js";
import { copySource } from "./copy.js";
import { activityDiffTemplate } from "./diff_view.js";
import { clip, steerSender } from "./format.js";
import { rowTitleRef } from "./refs.js";
import { readLinesTemplate } from "./read_view.js";
import { STOPPED_LINE_CLASS, cancelLineText, formatDuration } from "./timing.js";
import { emptyAnswerLine } from "./turn_events.js";

// A row's status (live, or a saved tool record's on reload): running,
// error, stopped (a task_wait the user's Stop ended), blocked (a guardrail
// denied it), else ok ("done"; a grep that found nothing is ok too, with
// a "no match" word, see statusParts).
const NAMED_STATUSES = ["running", "error", "stopped", "blocked"];

// A row's status as its parts: the mark's class (CSS draws the glyph), its
// label (aria-label and title) and the word an exception shows after the
// title (empty for done and running). A done grep that found nothing
// (+noMatch+, the activity's no_match) keeps the done mark and shows a
// muted "no match" word (its own class, wordCls).
export function statusParts(status, { noMatch = false } = {}) {
  const named = NAMED_STATUSES.includes(status);
  const cls = named ? status : "ok";
  const label = named ? status : "done";
  if (cls === "ok" && noMatch) return { cls, label, word: "no match", wordCls: "no-match" };
  return { cls, label, word: cls === "ok" || cls === "running" ? "" : label };
}

// role is bound too: lit sets bound attributes after the static ones, and
// the markup keeps the order a reload wrote before.
function statusMarkTemplate({ cls, label }) {
  return html`<span class="activity-status ${cls}" role=${"img"} aria-label=${label} title=${label}></span>`;
}

function statusWordTemplate({ cls, word, wordCls }) {
  return word ? html`<span class="activity-state ${wordCls || cls}">${word}</span>` : nothing;
}

// A reloaded row's ✂ mark: what an LLM context edit saved on its output
// sends the model instead (MessageParts.edit_marks): a stale stub and
// what it frees, a forget's note (or the output whose row carries it) and
// its kept lines, a forget still staged. The live rows get none (a reload
// shows them).
export function llmEditLine(edit) {
  if (!edit || typeof edit !== "object") return "";
  const kept = edit.kept ? ` · lines ${edit.kept} kept` : "";
  if (edit.kind === "forget") {
    if (edit.staged) return `✂ forget staged${kept}`;
    return `${edit.with ? `✂ forgotten with ${edit.with}` : `✂ forgotten: ${edit.note || ""}`}${kept}`;
  }
  if (edit.kind === "stale") {
    const tokens = Number(edit.tokens) > 0 ? ` · ~${compactTokens(Number(edit.tokens))}` : "";
    return `✂ stubbed: ${edit.note || "stale"}${tokens}`;
  }
  return "";
}

function compactTokens(n) {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k tokens` : `${n} tokens`;
}

function llmEditTemplate(row) {
  const line = llmEditLine(row.edit);
  if (!line) return nothing;
  const hover = `${row.tool_id ? `${row.tool_id}: ` : ""}${line}\nThe model is sent this instead of the output; the session keeps it.`;
  return html`<div class="activity-edit" title=${hover}>${line}</div>`;
}

// A tool row: its status mark, tool, title (else params; the full command,
// else the full params line, on hover), the word an exception shows, the
// call's duration, the full command (an execute/task_create's view, also
// while it runs), the output once done (its "[tool]" tag dropped, 300 chars,
// the rest on hover; a read of the file as-is also its numbered lines,
// closed: read_view.js), its images (+thumbs+(images) draws them) and an
// edit's collapsed diff, and a reloaded row's ✂ mark above its output. A
// part with nothing to say is left out. A reload renders toolRowTemplate;
// the live view renders toolRowInnerTemplate into its own row element
// (turn_view.js), again on each event: lit writes only what changed, so a
// part the user toggled (the raw command, the diff, the read lines) stays.
// +stop+: the live row's stop-task button (a node), after the title.
export function toolRowTemplate(row, opts = {}) {
  return html`<div class="activity-row" data-key=${row.key}>${toolRowInnerTemplate(row, opts)}</div>`;
}

export function toolRowInnerTemplate(row, { thumbs = () => nothing, stop = nothing } = {}) {
  const shown = row.title || row.params;
  const hover = rowHover(row);
  // A row with a ref (a file tool's file, else a plugin tool's first ref)
  // carries it on its title, which opens it, and its diff lines open it at
  // their line (refs.js; bindRowRefs binds a plugin's data to the title).
  const ref = shown ? rowTitleRef(row) : null;
  const attr = (value) => (value ? String(value) : nothing);
  const params = shown
    ? html`<span class=${`activity-params${ref?.kind ? " ref" : ""}`} title=${hover || nothing} data-ref-kind=${attr(ref?.kind)} data-ref-path=${attr(ref?.kind && ref.path)} data-ref-line=${attr(ref?.kind && ref.line)} data-ref-end-line=${attr(ref?.kind && ref.end_line)}>${shown}</span>`
    : nothing;
  // The name the model called the tool by when it was an alias's, or the
  // tool it was reached through (call_tool), dim.
  const alias = row.called_as ? html`<span class="activity-alias">(called as ${row.called_as})</span>`
    : row.via ? html`<span class="activity-alias">(via ${row.via})</span>` : nothing;
  const duration = formatDuration(row.duration_ms);
  const full = row.status === "running" ? "" : String(row.output || "").replace(/^\[[^\]]*\]\s*/, "");
  const output = full
    ? html`<div class="activity-output" title=${full}>${clip(full, 301)}</div>`
    : nothing;
  const status = statusParts(row.status, { noMatch: !!row.no_match });
  return html`${statusMarkTemplate(status)}<span class="activity-tool">${toolName(row)}</span>${params}${stop}${alias}${statusWordTemplate(status)}${duration ? html`<span class="activity-duration">${duration}</span>` : nothing}${commandBlockTemplate(row.view, row.title)}${llmEditTemplate(row)}${output}${full ? readLinesTemplate(row) : nothing}${row.images?.length ? thumbs(row.images) : nothing}${row.diff ? activityDiffTemplate(row.diff) : nothing}`;
}

// A prompt bubble's states and their badges: queued (waiting for its
// turn), steered (merged into a running turn), failed (its turn raised and
// gave it back). Any other state ("started", none) is a plain bubble.
export const BADGES = { queued: "queued", steered: "steered", failed: "failed" };

// A queued line's badge by its delivery (the composer's choice, the
// turn_enqueued's): what it waits for. next_step: the running turn's next
// step; cut: the cut (the ack may say it waits); queue: a turn of its own
// after this one.
const QUEUED_BADGES = { next_step: "waits for the next step", cut: "cutting in\u2026", queue: "after this turn" };

// A bubble's badge words for +state+ (and +delivery+ while queued); null
// for a plain bubble.
export function badgeText(state, delivery = null) {
  if (!BADGES[state]) return null;
  return (state === "queued" && QUEUED_BADGES[delivery]) || BADGES[state];
}

export function stateBadgeTemplate(state, delivery = null) {
  const text = badgeText(state, delivery);
  return text ? html`<span class="state-badge">${text}</span>` : nothing;
}

// A `!cmd`'s saved user message (the worker appends "!(<command>)\n<output>"
// for the next turn): its command line and its output, or null when the
// content is any other message. The command sits on the first line inside
// `!(` `)`; the output is everything after that first newline. A message
// that merely starts with "!" or "!(" without the newline shape is a plain
// message.
export function shellCommandMessage(content) {
  const text = String(content ?? "");
  const match = text.match(/^!\((.*)\)\n([\s\S]*)$/);
  if (!match) return null;
  return { line: `!${match[1]}`, text: match[2] };
}

// A `!cmd`'s history bubble: the same markup the live page draws for a
// command (app.js's drawCommandBubble): the line, the output in a
// pre.command-output.
export function commandBubbleTemplate({ line, text }) {
  const body = text ? html`<pre class="command-output">${text}</pre>` : nothing;
  return html`<div class="bubble command"><div class="command-line">${line}</div>${body}</div>`;
}

// A user message's body: runs of `>` lines become <blockquote>s, the rest
// stays text. The bubble is pre-wrap, so the blank lines around a quote
// are dropped (the blockquote's margin spaces it instead).
export function userBodyTemplate(content) {
  const text = String(content ?? "").replace(/\r\n?/g, "\n");
  const blocks = [];
  for (const line of text.split("\n")) {
    const m = /^ {0,3}> ?(.*)$/.exec(line);
    const kind = m ? "quote" : "text";
    const last = blocks[blocks.length - 1];
    if (last?.kind === kind) last.lines.push(m ? m[1] : line);
    else blocks.push({ kind, lines: [m ? m[1] : line] });
  }
  if (!blocks.some((b) => b.kind === "quote")) return String(content ?? "");
  return blocks.map((b) => {
    if (b.kind === "quote") return html`<blockquote>${b.lines.join("\n")}</blockquote>`;
    const body = b.lines.join("\n").replace(/^\s*\n/, "").replace(/\n\s*$/, "");
    return body.trim() ? body : nothing;
  });
}

// An answer's bubble (+cls+: a report reply's; +at+: its message's index,
// data-answer-at): an assistant's rendered markdown (the server's html,
// sanitized there) set as it is, as the live turn end sets it
// (answer_refs.js applyFinalAnswer), else its text, set whole (no lit
// markers inside: the bubble's nodes are the live one's). Its markdown
// source is kept for the copy button when it shows rendered html.
export function answerBubbleTemplate(message, { cls = "", at = null } = {}) {
  const rendered = message?.role === "assistant" && typeof message.html === "string";
  const user = !rendered && message?.role === "user";
  const klass = `bubble output${cls}${rendered ? " markdown" : ""}`;
  const answerAt = at ?? nothing;
  const source = rendered || user ? copySource(message) : nothing;
  if (rendered) return html`<div class=${klass} data-answer-at=${answerAt} data-copy-source=${source} .innerHTML=${message.html}></div>`;
  if (user) return html`<div class=${klass} data-answer-at=${answerAt} data-copy-source=${source}>${userBodyTemplate(message.content)}</div>`;
  return html`<div class=${klass} data-answer-at=${answerAt} data-copy-source=${source} .textContent=${String(message?.content ?? "")}></div>`;
}

// A context note's bubble (background the user or another session pushed
// in; the model reads it, nobody asked it anything): who sent it, then its
// text.
export function noteBubbleTemplate(note) {
  const from = note?.label ? `note from ${note.label}` : "note";
  return html`<div class="bubble note"><div class="note-line">${from}</div><div class="note-text">${note?.content ?? ""}</div></div>`;
}

// A plugin's steer (a nudge put into the running turn): one line that
// names who nudged the model, its text collapsed under it. +bubble+: on its
// own between bubbles (no step holds it), not a row of a step.
export function steerRowTemplate({ source, text } = {}, { bubble = false } = {}) {
  const sender = steerSender(source);
  const who = sender ? `${sender} nudged the model` : "nudged the model";
  return html`<details class=${`${bubble ? "bubble " : ""}steer-row`}><summary>${who}</summary><div class="steer-text">${text ?? ""}</div></details>`;
}

// A user's line: who sent it (+label+, a delegate report's or another
// client's), its body (`>` lines as quotes) and +thumbs+ (its images'
// template), its state's badge. +message+: { content, display } (the copy
// source keeps the text as written). +step+: the step that read a line
// merged mid-turn (a reload's; a resolved question goes before it).
// The live page's own: +own+ (this tab sent it), +enqueuedId+ and +key+
// (its normalized text: an echo waiting for its id is matched by it).
// +delivery+: how it was sent into a running turn (next_step, cut, queue):
// its data-delivery and its queued badge's words.
export function userBubbleTemplate(message, { label = null, state = null, step = null, thumbs = nothing, own = false, enqueuedId = null, key = null, delivery = null } = {}) {
  const named = BADGES[state] ? state : null;
  const from = label ? html`<span class="origin-label">${label}</span>` : nothing;
  return html`<div class=${`bubble user${named ? ` ${named}` : ""}`} data-user-state=${named || nothing} data-step=${step ? Number(step) : nothing} data-copy-source=${copySource({ ...message, role: "user" })} data-user-content=${key !== null ? key : nothing} data-own=${own ? "1" : nothing} data-enqueued-id=${enqueuedId || nothing} data-delivery=${delivery || nothing}>${from}<div class="user-message">${userBodyTemplate(message?.content)}${thumbs}</div>${stateBadgeTemplate(named, delivery)}</div>`;
}

// The notice of a turn that ended with no answer (the server's
// empty_answer item, turn_summary.empty_answer live): a muted row like the
// loop's retry row, where the answer would be.
export function emptyAnswerTemplate(item) {
  return html`<div class="bubble hook-notice empty-answer">${emptyAnswerLine(item)}</div>`;
}

// A re-rendered turn's cancel line (a .bubble.cancel.stopped, as live's
// addEndBubble), nothing when the turn record is not a canceled one.
export function cancelLineTemplate(record) {
  if (record?.status !== "canceled") return nothing;
  return html`<div class=${STOPPED_LINE_CLASS}>${cancelLineText(record.cancellation_reason, record.cancelled_by)}</div>`;
}

// +template+'s one top-level element, rendered once (the live page's
// bubbles: their classes and badge change by hand after this).
export function elementOf(template) {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return frag.firstElementChild;
}
