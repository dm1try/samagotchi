// A plugin's card (docs/plugins.md, Cards): a title, a body and actions,
// each action a command line the session runs. app.js places and updates
// the element; this module draws it and says where it goes.
import { escapeHtml, recapPlace } from "./format.js";

// The card's class: a warn card wears the warning colour; a notice is a
// one-line row.
export function cardClass(card) {
  return "bubble plugin-card" + (card?.level === "warn" ? " warn" : "") + (isNoticeCard(card) ? " notice" : "");
}

// The longest body a notice row carries; a longer one is a card to read.
export const NOTICE_CHARS = 160;

// Whether a card is a notice (check-in's "Nudged the model at 105 tool
// calls."): info level, nothing to click, a body of one short line. It
// shows as a collapsed one-line row, "▸ check-in: Nudged …", as the tool
// rows and the resolved question cards do; a click opens it. A warn card,
// one that asks (actions) and one with more to read stay cards.
export function isNoticeCard(card) {
  if (!card || card.level === "warn") return false;
  if ((card.actions || []).some((a) => a && a.command)) return false;
  const body = String(card.body ?? "").trim();
  return !body.includes("\n") && body.length <= NOTICE_CHARS;
}

// A notice's one line: "title: body" (the title alone for no body).
export function noticeCardLine(card) {
  const title = String(card?.title ?? "").trim();
  const body = String(card?.body ?? "").trim();
  return title && body ? `${title}: ${body}` : title || body;
}

// A notice's markup inside its <details>: the line as the summary, and
// where it came from when the row is opened (the line wraps then).
export function noticeInnerHtml(card) {
  const title = String(card?.title ?? "").trim();
  const source = String(card?.source ?? "").trim();
  const from = source && source !== title ? `<div class="notice-from">from <span class="card-source">${escapeHtml(source)}</span></div>` : "";
  return `<summary>${escapeHtml(noticeCardLine(card))}</summary>${from}`;
}

// Whether a card shown as a row of a step leaves the turn's block when the
// turn ends and the block collapses (it would be hidden then): a warn card
// always, and any card of a turn that ended without completing (canceled,
// failed, the worker gone), which is often the card saying why and how to
// steer. It goes after the turn's end line, where a reload puts it. An info
// card of a completed turn stays a row of its step.
export function leavesBlock({ warn = false, kind = "completed" } = {}) {
  return warn || kind !== "completed";
}

// The body: the server's body_html (rendered markdown, sanitized; or the
// escaped text in a <pre>), else the plain text in a <pre> (a live event
// carries no html; the page's ?cards=1 re-read brings it).
export function cardBodyHtml(card) {
  if (typeof card?.body_html === "string") return card.body_html;
  const body = String(card?.body ?? "");
  return body.trim() ? `<pre>${escapeHtml(body)}</pre>` : "";
}

// The card's inner markup: its head (title, source), body and one button
// per action (the command as its tooltip and data).
export function cardInnerHtml(card) {
  const source = card.source ? `<span class="card-source">${escapeHtml(card.source)}</span>` : "";
  const head = `<div class="card-head"><span class="card-title">${escapeHtml(card.title || "")}</span>${source}</div>`;
  const bodyHtml = cardBodyHtml(card);
  const body = bodyHtml ? `<div class="card-body">${bodyHtml}</div>` : "";
  const actions = (card.actions || []).filter((a) => a && a.command);
  const buttons = actions.length
    ? `<div class="card-actions">${actions.map((a) =>
      `<button type="button" class="card-action ghost" data-command="${escapeHtml(a.command)}" title="${escapeHtml(a.command)}">${escapeHtml(a.label || a.command)}</button>`).join("")}</div>`
    : "";
  return `${head}${body}${buttons}<div class="card-error hidden"></div>`;
}

// Where a snapshot's card or between-turns notice goes: before the user
// bubble that starts the first turn after it (turns_since counts the turns
// completed after it), or null for the end of the history.
export function cardPlace(userBubbles, card) {
  return recapPlace(userBubbles, card?.turns_since);
}

// A snapshot's cards: the ones placed in the history, the running turn's
// (a row of its current step once the turn is drawn), and the ones that
// came during the running turn but aren't its own (an anytime command's,
// such as /btw: after the running turn once it is drawn, as they came).
// The running turn's own rows (a hook's notice, a retry) are left out:
// they come with the turn's parts (snapshotEvents).
export function splitSnapshotCards(cards) {
  const list = Array.isArray(cards) ? cards : [];
  return {
    placed: list.filter((c) => !c.current && !c.during),
    current: list.filter((c) => c.current && isCard(c)),
    during: list.filter((c) => !c.current && c.during),
  };
}

// An entry of the snapshot's cards that is a card (not a notice or a row).
export function isCard(entry) {
  return (entry?.type ?? "card") === "card";
}

// Where a snapshot's turn notice (a hook's notice during a turn, in_turn)
// goes in its reloaded turn's block: the step of its iteration (the
// iteration-th .gen, 0-based index here) and the key of the tool row it
// came before (it came after +calls+ of that step's calls started), or null
// for a notice not of a turn. One from before the first generation (a
// before_turn hook's) has no iteration: the first step, as live.
export function turnNoticePlace(notice) {
  if (!notice?.in_turn) return null;
  const iteration = notice.iteration == null ? 1 : Number(notice.iteration);
  if (!Number.isInteger(iteration) || iteration < 1) return null;
  return { step: iteration - 1, rowKey: `${iteration}:${(Number(notice.calls) || 0) + 1}` };
}
