// The turn's pieces as HTML, one builder for the live page and a reload:
// a tool row, a prompt bubble and the notice of a turn with no answer. The
// live page makes its elements from the same markup a reload writes
// (htmlElement), so the two can't drift apart. Pure but htmlElement: `node --test` covers it.
import { toolName } from "./activity.js";
import { commandBlockHtml, rowHover } from "./command_view.js";
import { copySourceAttr } from "./copy.js";
import { activityDiffHtml } from "./diff_view.js";
import { escapeHtml, userBodyHtml } from "./format.js";
import { formatDuration } from "./timing.js";
import { emptyAnswerLine } from "./turn_events.js";

// A row's status (live, or a saved tool record's on reload): running,
// error, stopped (a task_wait the user's Stop ended), blocked (a guardrail
// denied it), else ok ("done").
const NAMED_STATUSES = ["running", "error", "stopped", "blocked"];

// A row's status as its parts: the mark's class (CSS draws the glyph), its
// label (aria-label and title) and the word an exception shows after the
// title (empty for done and running).
export function statusParts(status) {
  const named = NAMED_STATUSES.includes(status);
  const cls = named ? status : "ok";
  const label = named ? status : "done";
  return { cls, label, word: cls === "ok" || cls === "running" ? "" : label };
}

function statusMarkHtml({ cls, label }) {
  return `<span class="activity-status ${cls}" role="img" aria-label="${label}" title="${label}"></span>`;
}

function statusWordHtml({ cls, word }) {
  return word ? `<span class="activity-state ${cls}">${word}</span>` : "";
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

function llmEditHtml(row) {
  const line = llmEditLine(row.edit);
  if (!line) return "";
  const hover = `${row.tool_id ? `${row.tool_id}: ` : ""}${line}\nThe model is sent this instead of the output; the session keeps it.`;
  return `<div class="activity-edit" title="${escapeHtml(hover)}">${escapeHtml(line)}</div>`;
}

// A tool row: its status mark, tool, title (else params; the full command,
// else the full params line, on hover), the word an exception shows, the
// call's duration, the full command (an execute/task_create's view, also
// while it runs), the output once done (its "[tool]" tag dropped, 300 chars,
// the rest on hover), its images (+thumbs+(images) draws them) and an
// edit's collapsed diff, and a reloaded row's ✂ mark above its output. A
// part with nothing to say is left out.
export function toolRowHtml(row, { thumbs = () => "" } = {}) {
  return `<div class="activity-row" data-key="${escapeHtml(row.key)}">${toolRowInnerHtml(row, { thumbs })}</div>`;
}

export function toolRowInnerHtml(row, { thumbs = () => "" } = {}) {
  const shown = row.title || row.params;
  const hover = rowHover(row) ? ` title="${escapeHtml(rowHover(row))}"` : "";
  const params = shown ? `<span class="activity-params"${hover}>${escapeHtml(shown)}</span>` : "";
  const duration = formatDuration(row.duration_ms);
  const full = row.status === "running" ? "" : String(row.output || "").replace(/^\[[^\]]*\]\s*/, "");
  const output = full
    ? `<div class="activity-output" title="${escapeHtml(full)}">${escapeHtml(full.length > 300 ? `${full.slice(0, 300)}…` : full)}</div>`
    : "";
  const status = statusParts(row.status);
  return `${statusMarkHtml(status)}<span class="activity-tool">${escapeHtml(toolName(row))}</span>${params}${statusWordHtml(status)}` +
    `${duration ? `<span class="activity-duration">${escapeHtml(duration)}</span>` : ""}` +
    `${commandBlockHtml(row.view, row.title)}${llmEditHtml(row)}${output}` +
    `${row.images?.length ? thumbs(row.images) : ""}${row.diff ? activityDiffHtml(row.diff) : ""}`;
}

// A prompt bubble's states and their badges: queued (waiting for its
// turn), steered (merged into a running turn), failed (its turn raised and
// gave it back). Any other state ("started", none) is a plain bubble.
export const BADGES = { queued: "queued", steered: "steered", failed: "failed" };

export function stateBadgeHtml(state) {
  return BADGES[state] ? `<span class="state-badge">${escapeHtml(BADGES[state])}</span>` : "";
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
