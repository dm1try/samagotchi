// The turn's pieces as HTML, one builder for the live page and a reload:
// a prompt bubble and the notice of a turn with no answer. The live page
// makes its elements from the same markup a reload writes (htmlElement), so
// the two can't drift apart. Pure but htmlElement: `node --test` covers it.
import { copySourceAttr } from "./copy.js";
import { escapeHtml, userBodyHtml } from "./format.js";
import { emptyAnswerLine } from "./turn_events.js";

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
export const EMPTY_ANSWER_CLASS = "bubble hook-notice empty-answer";
export function emptyAnswerHtml(item) {
  return `<div class="${EMPTY_ANSWER_CLASS}">${escapeHtml(emptyAnswerLine(item))}</div>`;
}

// The element +html+ (one top-level element) describes.
export function htmlElement(html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  return template.content.firstElementChild;
}
