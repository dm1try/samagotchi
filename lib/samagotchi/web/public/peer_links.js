// The peer exchange in the conversation: the controller that draws what the
// peers model (peer_data.js) knows into the slots the templates leave
// (turn_html.js: a send row's `.peer-slot`; peer_note.js: an answer's ↑ and
// "Read the full answer"), and the jumps between a send and its answer.
// Finished rows are never drawn again and a reload makes them anew, so the
// state that comes later is drawn here: after each history draw
// (session_view.js renderSessionView) and on the model's onChange.
// docs/internals/web-frontend.md, The peer exchange.
// Its own module: new exports go in new modules (web-frontend.md).

import { html, nothing, render } from "./vendor/lit-html.js";
import { pillTemplate } from "./peer_exchange.js";
import { EXCHANGES_CAP } from "./peer_data.js";
import { showRow } from "./refs.js";
import { revealInHistory } from "./history_reveal.js";

const SLOTS = ".peer-slot[data-peer-ref]";
const ANSWERS = ".bubble.note.peer-answer";

// +a+ comes before +b+ in the page.
const precedes = (a, b) => !!(a.compareDocumentPosition(b) & 4 /* DOCUMENT_POSITION_FOLLOWING */);

// The answer's ↑: back to the send it answers (kind · title), nothing for
// an answer no send claims (or one not read yet).
export function upTemplate(exchange) {
  if (!exchange?.id) return nothing;
  const what = [exchange.kind, exchange.title].filter(Boolean).join(" · ") || "the send";
  return html`<button type="button" class="peer-up" data-peer-jump="send" data-peer-id=${exchange.id}
    aria-label=${`${what}: go to the send`}>${what}<span aria-hidden="true"> ↑</span></button>`;
}

// "Read the full answer": the newest answer of a peer only (its outbox keeps
// one text), and not one whose bubble holds its text (data-peer-inline).
export function fullTemplate(newest) {
  return newest ? html`<button type="button" class="peer-full" data-peer-full="1">Read the full answer</button>` : nothing;
}

// +peers+ the model (peer_data.js); +roots+() the elements a turn's rows can
// be in (the history and the stage); +running+() whether a turn runs;
// +showText+(source) opens that context source's text (context_chips.js);
// +renderMarkdown+(text) a text's sanitized markdown HTML or null
// (markdown_place.js; none: the peer's text stays plain); +behavior+() the
// scroll's.
//
// @return {draw(), drawn(), hasPeer(), hasSend(id), showSend(id), reset()}
export function createPeerLinks({ peers, roots, running = () => false, showText = () => {}, renderMarkdown = null, behavior = smooth } = {}) {
  const all = (selector) => roots().filter(Boolean).flatMap((root) => [...root.querySelectorAll(selector)]);
  // The peer texts already asked for (each is asked once; a failed read
  // keeps the plain text).
  const asked = new WeakSet();

  // A slot of the running turn (the stage's, or a turn opened in the history).
  const live = (slot) => running() && !!slot.closest(".turn-stage, [data-opened-turn]");

  // A send whose id the read doesn't have: did it not go out ("not sent"),
  // or is it only not in the read (unknown: no pill)? Not sent when the row
  // says it failed, or, once its turn has ended, when its peer's list is
  // whole (under the server's cap) or holds a send drawn before this row
  // (the list is the newest exchanges, so this row is among them). A peer
  // the read doesn't name (detached, an older chi web) is unknown.
  function notSent(slot, slots) {
    const row = slot.closest(".activity-row");
    if (/^Error:/.test(slot.getAttribute("title") || "") || row?.querySelector(":scope > .activity-status.error")) return true;
    if (!peers.loaded() || live(slot)) return false;
    const tool = row?.dataset.tool || "";
    const peer = tool.endsWith("_send") ? peers.peer(tool.slice(0, -"_send".length)) : null;
    if (!peer) return false;
    const listed = (peer.exchanges || []).filter((ex) => ex?.id);
    if ((peer.exchanges || []).length < EXCHANGES_CAP) return true;
    const ids = new Set(listed.map((ex) => ex.id));
    return slots.some((other) => other !== slot && ids.has(other.dataset.peerRef) && precedes(other, slot));
  }

  function draw() {
    const now = Date.now();
    const slots = all(SLOTS);
    for (const slot of slots) {
      const exchange = peers.exchange(slot.dataset.peerRef);
      const ended = !exchange && notSent(slot, slots);
      render(pillTemplate(exchange, { now, ended, title: slot.getAttribute("title") || "" }), slot);
    }
    const notes = all(ANSWERS);
    const newest = new Map();
    for (const note of notes) newest.set(note.dataset.peerSource || "", note);
    for (const note of notes) {
      const up = note.querySelector(":scope > .peer-head > .peer-up-slot");
      if (up) render(upTemplate(answerOf(note)), up);
      const full = note.querySelector(":scope > .peer-foot > .peer-full-slot");
      const last = newest.get(note.dataset.peerSource || "") === note && !!note.dataset.peerSource;
      if (full) render(fullTemplate(last && !note.dataset.peerInline), full);
      const text = note.querySelector(":scope > .peer-text[data-peer-md]:not(.markdown)");
      if (text) renderText(text);
    }
  }

  // A bubble's peer text as its markdown, as the answers' (POST
  // /api/render, sanitized there): its source stays in data-peer-md, which
  // history_shape.js reads, so live and an offscreen reload read alike.
  function renderText(el) {
    if (!renderMarkdown || asked.has(el)) return;
    asked.add(el);
    const source = el.dataset.peerMd;
    Promise.resolve(renderMarkdown(source)).then((rendered) => {
      if (!rendered || el.dataset.peerMd !== source) return;
      // Sanitized on the server (POST /api/render).
      el.innerHTML = rendered;
      el.classList.add("markdown", "md-compact");
    }).catch(() => {});
  }

  function answerOf(note) {
    const { peerName, peerSerial, peerRe } = note.dataset;
    return peers.answer(peerName, peerSerial ?? null, peerRe || null);
  }

  // Focus lands on the jump's target (it isn't focusable by itself).
  function land(el) {
    if (!el.hasAttribute("tabindex")) el.setAttribute("tabindex", "-1");
    el.focus?.({ preventScroll: true });
  }

  // ↓: the send's answer, the last bubble drawn for its serial.
  function toAnswer(slot) {
    const ex = peers.exchange(slot.dataset.peerRef);
    const serial = ex?.answer?.serial;
    if (serial === undefined || serial === null) return;
    const note = all(ANSWERS).filter((n) => n.dataset.peerName === ex.peer && n.dataset.peerSerial === String(serial)).at(-1);
    if (!note) return;
    revealInHistory(note);
    note.scrollIntoView?.({ block: "center", behavior: behavior() });
    land(note);
  }

  // ↑: the send's row, the last one with its id before the answer (a resend
  // has one id), else the last one.
  function toSend(button) {
    showSend(button.dataset.peerId, button.closest(ANSWERS));
  }

  // The row of send +id+ (the last before +before+, when given), shown and
  // focused; false when none is drawn.
  function showSend(id, before = null) {
    const slots = all(SLOTS).filter((s) => s.dataset.peerRef === id);
    const slot = (before && slots.filter((s) => precedes(s, before)).at(-1)) || slots.at(-1);
    const row = slot?.closest(".activity-row");
    if (!row) return false;
    showRow(row, { behavior: behavior() });
    land(row);
    return true;
  }

  function onClick(e) {
    const jump = e.target.closest?.("[data-peer-jump]");
    if (jump?.dataset.peerJump === "answer") {
      const slot = jump.closest(SLOTS);
      if (slot) toAnswer(slot);
    } else if (jump?.dataset.peerJump === "send") toSend(jump);
    else if (e.target.closest?.("[data-peer-full]")) {
      const source = e.target.closest(ANSWERS)?.dataset.peerSource;
      if (source) showText(source);
    }
  }
  for (const root of roots().filter(Boolean)) root.addEventListener("click", onClick);

  return {
    draw,
    // A history drawn (a session's read): its slots filled with what is
    // known, then read again.
    drawn() {
      draw();
      return peers.refresh();
    },
    hasPeer: () => all(SLOTS).length > 0 || all(ANSWERS).length > 0,
    // Whether send +id+'s row is drawn, and a jump to it (the peer chip's
    // exchange list, peer_chip.js).
    hasSend: (id) => all(SLOTS).some((s) => s.dataset.peerRef === id),
    showSend: (id) => showSend(id),
    reset: () => peers.clear(),
  };
}

function smooth() {
  return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth";
}
