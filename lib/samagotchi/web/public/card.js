// A plugin's card (docs/plugins.md, Cards): a title, a body and actions,
// each action a command line the session runs. app.js places and updates
// the element; this module draws it (lit-html templates) and says where it
// goes.
import { html, nothing, render } from "./vendor/lit-html.js";
import { unsafeHTML } from "./vendor/directives/unsafe-html.js";
import { recapPlace } from "./format.js";

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

// A notice inside its <details>: the line as the summary, and where it
// came from when the row is opened (the line wraps then).
export function noticeTemplate(card) {
  const title = String(card?.title ?? "").trim();
  const source = String(card?.source ?? "").trim();
  const from = source && source !== title ? html`<div class="notice-from">from <span class="card-source">${source}</span></div>` : nothing;
  return html`<summary>${noticeCardLine(card)}</summary>${from}`;
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
// escaped text in a <pre>) as it is, else the plain text in a <pre> (a
// live event carries no html; the page's ?cards=1 re-read brings it);
// null for none. The same body_html again keeps its nodes (unsafeHTML
// renders a string it rendered last time as it is).
export function cardBodyTemplate(card) {
  if (typeof card?.body_html === "string") return card.body_html ? unsafeHTML(card.body_html) : null;
  const body = String(card?.body ?? "");
  return body.trim() ? html`<pre>${body}</pre>` : null;
}

// The card: its head (title, source), body and one button per action (the
// command as its tooltip and data), then the line a failed action writes.
export function cardTemplate(card) {
  const source = card.source ? html`<span class="card-source">${card.source}</span>` : nothing;
  const body = cardBodyTemplate(card);
  const actions = (card.actions || []).filter((a) => a && a.command);
  const buttons = actions.length
    ? html`<div class="card-actions">${actions.map((a) =>
      html`<button type="button" class="card-action ghost" data-command=${a.command} title=${a.command}>${a.label || a.command}</button>`)}</div>`
    : nothing;
  return html`<div class="card-head"><span class="card-title">${card.title || ""}</span>${source}</div>${body ? html`<div class="card-body">${body}</div>` : nothing}${buttons}<div class="card-error hidden"></div>`;
}

// A card element → the card it shows, as drawCard drew it.
const DRAWN = new WeakMap();

// +card+ drawn on +el+ (a notice on a <details>, a card on a <div>; one
// that turns into the other kind, btw's "thinking…" → its answer, is
// drawn on a new element in its place). Returns the element drawn. A
// redraw writes only what changed: an open notice stays open, a body
// that didn't change keeps its nodes (a selection in it), and the same
// body again from the stream (text, no html) keeps the rendered one. A
// failed action's line goes, as the card is new.
export function drawCard(el, card) {
  const notice = isNoticeCard(card);
  if (el.tagName !== (notice ? "DETAILS" : "DIV")) {
    const fresh = el.ownerDocument.createElement(notice ? "details" : "div");
    el.replaceWith(fresh);
    el = fresh;
  }
  el.className = cardClass(card);
  el.dataset.cardId = card.id;
  // A running turn's own card (the stage's status waits on one that asks).
  if (card.in_turn) el.dataset.inTurn = "1";
  else delete el.dataset.inTurn;
  const drawn = DRAWN.get(el);
  const sameBody = card.body_html === undefined && drawn && String(drawn.body ?? "") === String(card.body ?? "");
  paint(el, sameBody ? { ...card, body_html: drawn.body_html } : card);
  const error = el.querySelector(":scope > .card-error");
  if (error) {
    error.textContent = "";
    error.classList.add("hidden");
  }
  return el;
}

function paint(el, card) {
  render(isNoticeCard(card) ? noticeTemplate(card) : cardTemplate(card), el);
  DRAWN.set(el, card);
}

// The rendered body a re-read brought (the snapshot's +card+ with its
// body_html) onto a card drawn with the same body text; a no-op for any
// other.
export function refreshCardBody(el, card) {
  const drawn = DRAWN.get(el);
  if (!drawn || isNoticeCard(drawn) || typeof card?.body_html !== "string" || String(drawn.body ?? "") !== String(card.body ?? "")) return;
  paint(el, { ...drawn, body_html: card.body_html });
}

// Where a snapshot's card or between-turns notice goes: before the user
// bubble that starts the first turn after it (turns_since counts the turns
// completed after it), or null for the end of the history.
export function cardPlace(userBubbles, card) {
  return recapPlace(userBubbles, card?.turns_since);
}

// Whether a notice stands in for something this page already shows: its
// fallback_for names a capability the server says the page has (the
// session JSON's capabilities, e.g. { display: true } when answers render
// as markdown, so a hook's links are links). Such a notice isn't drawn.
export function shownElsewhere(notice, capabilities) {
  return !!notice?.fallback_for && capabilities?.[notice.fallback_for] === true;
}

// A snapshot's cards: the ones placed in the history, the running turn's
// (a row of its current step once the turn is drawn), and the ones that
// came during the running turn but aren't its own (an anytime command's,
// such as /btw: after the running turn once it is drawn, as they came).
// The running turn's own rows (a hook's notice, a retry) are left out:
// they come with the turn's parts (snapshotEvents). So is a notice the
// page shows elsewhere (shownElsewhere).
export function splitSnapshotCards(cards, capabilities = null) {
  const list = (Array.isArray(cards) ? cards : []).filter((c) => !shownElsewhere(c, capabilities));
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
