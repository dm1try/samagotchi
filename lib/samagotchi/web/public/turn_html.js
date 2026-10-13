// The turn's pieces, one builder for the live page and a reload: a tool
// row (a lit-html template), a prompt bubble and the notice of a turn with
// no answer. The live page makes its elements from the same template or
// markup a reload writes (htmlElement), so the two can't drift apart.
// `node --test` covers it (the templates on the happy-dom shim).
import { toolName } from "./activity.js";
import { html, nothing } from "./vendor/lit-html.js";
import { commandBlockTemplate, rowHover } from "./command_view.js";
import { copySourceAttr } from "./copy.js";
import { activityDiffTemplate } from "./diff_view.js";
import { escapeHtml, userBodyHtml } from "./format.js";
import { rowTitleRef } from "./refs.js";
import { readLinesTemplate } from "./read_view.js";
import { formatDuration } from "./timing.js";
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
  // The name the model called the tool by when it was an alias's, dim.
  const alias = row.called_as ? html`<span class="activity-alias">(called as ${row.called_as})</span>` : nothing;
  const duration = formatDuration(row.duration_ms);
  const full = row.status === "running" ? "" : String(row.output || "").replace(/^\[[^\]]*\]\s*/, "");
  const output = full
    ? html`<div class="activity-output" title=${full}>${full.length > 300 ? `${full.slice(0, 300)}…` : full}</div>`
    : nothing;
  const status = statusParts(row.status, { noMatch: !!row.no_match });
  return html`${statusMarkTemplate(status)}<span class="activity-tool">${toolName(row)}</span>${params}${stop}${alias}${statusWordTemplate(status)}${duration ? html`<span class="activity-duration">${duration}</span>` : nothing}${commandBlockTemplate(row.view, row.title)}${llmEditTemplate(row)}${output}${full ? readLinesTemplate(row) : nothing}${row.images?.length ? thumbs(row.images) : nothing}${row.diff ? activityDiffTemplate(row.diff) : nothing}`;
}

// A prompt bubble's states and their badges: queued (waiting for its
// turn), steered (merged into a running turn), failed (its turn raised and
// gave it back). Any other state ("started", none) is a plain bubble.
export const BADGES = { queued: "queued", steered: "steered", failed: "failed" };

export function stateBadgeHtml(state) {
  return BADGES[state] ? `<span class="state-badge">${escapeHtml(BADGES[state])}</span>` : "";
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
export function commandBubbleHtml({ line, text }) {
  const body = text ? `<pre class="command-output">${escapeHtml(text)}</pre>` : "";
  return `<div class="bubble command"><div class="command-line">${escapeHtml(line)}</div>${body}</div>`;
}

// A user's line: who sent it (+label+, a delegate report's or another
// client's), its body (`>` lines as quotes) and +thumbs+ (its images'
// markup), its state's badge. +message+: { content, display } (the copy
// source keeps the text as written). +step+: the step that read a line
// merged mid-turn (a reload's; a resolved question goes before it).
// The live page's own: +own+ (this tab sent it), +enqueuedId+ and +key+
// (its normalized text: an echo waiting for its id is matched by it).
export function userBubbleHtml(message, { label = null, state = null, step = null, thumbs = "", own = false, enqueuedId = null, key = null } = {}) {
  const named = BADGES[state] ? state : null;
  const attrs = [
    `class="bubble user${named ? ` ${named}` : ""}"`,
    named ? `data-user-state="${named}"` : "",
    step ? `data-step="${Number(step)}"` : "",
  ].filter(Boolean).join(" ");
  const live = [
    key !== null ? ` data-user-content="${escapeHtml(key)}"` : "",
    own ? ' data-own="1"' : "",
    enqueuedId ? ` data-enqueued-id="${escapeHtml(enqueuedId)}"` : "",
  ].join("");
  const from = label ? `<span class="origin-label">${escapeHtml(label)}</span>` : "";
  return `<div ${attrs}${copySourceAttr({ ...message, role: "user" }, false)}${live}>${from}` +
    `<div class="user-message">${userBodyHtml(message?.content)}${thumbs}</div>${stateBadgeHtml(named)}</div>`;
}

// The notice of a turn that ended with no answer (the server's
// empty_answer item, turn_summary.empty_answer live): a muted row like the
// loop's retry row, where the answer would be.
export function emptyAnswerHtml(item) {
  return `<div class="bubble hook-notice empty-answer">${escapeHtml(emptyAnswerLine(item))}</div>`;
}

// The element +html+ (one top-level element) describes.
export function htmlElement(html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  return template.content.firstElementChild;
}
