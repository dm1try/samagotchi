// A paired peer in the session bar: one chip per peer the peers model
// (peer_data.js, GET …/peers: the session's mailbox) names as paired, that
// says how the pairing stands (paired, waiting, answered, can't send,
// answers only), and that chip's popover (how chi and the peer reach each
// other, the last exchanges with what chi did with each message, View
// latest answer, Status card, Unpair). Pure templates and models: the
// chips' controller (context_chips.js) draws them. docs/internals/
// web-frontend.md, The peer exchange. Its own module: new exports go in new
// modules.

import { html, nothing } from "./vendor/lit-html.js";
import { spanText, verdictWord } from "./peer_exchange.js";
import { wallClock } from "./format.js";

// A peer chip's key among the chips ("peer:claude"); an ordinary chip's is
// its source's name, which never holds a ":" (ContextSources' names).
export const peerKey = (name) => `peer:${name}`;

// How many exchanges the popover lists (the newest).
export const POPOVER_EXCHANGES = 8;

// The peers model's rows as chips' groups: {key, name, label, peer} for each
// paired one (its link.json: paired_at), in the model's order. A peer that
// was unpaired keeps its messages but has no chip.
export function peerGroups(peers) {
  return (peers || []).filter((peer) => peer?.name && peer.paired_at)
    .map((peer) => ({ key: peerKey(peer.name), name: peer.name, label: peer.label || peer.name, peer }));
}

// A message no turn has read yet: no receipt (chi hasn't taken it), or one
// that holds it as a note (held, noted).
const unread = (message) => !message?.receipt || ["held", "noted"].includes(message.receipt.state);

// The sends among +exchanges+ (newest first): an unclaimed answer has no id.
const sends = (exchanges) => (exchanges || []).filter((ex) => ex?.id);
const ASKS = ["validate", "question"];
const messagesOf = (group) => group?.peer?.messages || [];

// The newest send failed and the peer hasn't paired again since: pairing
// again writes a new link (paired_at) after the failed send's time.
export function cantSend(group, exchanges) {
  const newest = sends(exchanges)[0];
  if (newest?.state !== "failed") return false;
  const paired = Date.parse(group?.peer?.paired_at || "");
  const failed = Date.parse(newest.at || "");
  return !(paired > failed);
}
const since = (iso, now) => {
  const at = Date.parse(iso || "");
  return Number.isNaN(at) ? null : now - at;
};

// The chip of +group+: the first state that applies.
// - answers-only: the pairing has no address (chi can't send);
// - cant-send: the newest send failed (the transport refused it);
// - waiting: the newest validate or question send has no answer (its age the send's);
// - answered: its newest message no turn has read (its age the message's), with the dot;
// - paired otherwise.
// +exchanges+: the peer's from GET …/peers, newest first.
// @return {key, name, state, label, title, dot}
export function peerChipModel(group, exchanges = [], now = Date.now()) {
  const all = sends(exchanges);
  const ask = all.find((ex) => ASKS.includes(ex.kind));
  const newest = messagesOf(group)[0];
  let state = "paired";
  let words = "paired";
  let why = "paired: chi can send to it and it answers with chi peer say";
  if (!group.peer?.can_send) {
    state = "answers-only";
    words = "answers only";
    why = "paired with no address chi can reach: it answers, chi can't send to it";
  } else if (cantSend(group, exchanges)) {
    state = "cant-send";
    words = "can't send";
    why = `the last send didn't go through: pair again from ${group.label}`;
  } else if (ask?.state === "waiting") {
    const age = since(ask.at, now);
    state = "waiting";
    words = age === null ? "waiting" : `waiting ${spanText(age)}`;
    why = [ask.kind, ask.title].filter(Boolean).join(" · ") || "a send";
    why = `waiting for its answer to ${why}`;
  } else if (newest && unread(newest)) {
    const age = since(newest.at, now);
    state = "answered";
    words = age === null ? "answered" : `answered ${spanText(age)}`;
    why = "a message the agent hasn't read yet";
  }
  return { key: group.key, name: group.key, state, label: `${group.label} · ${words}`, title: why,
           dot: state === "answered", peer: true };
}

// An exchange's state as the popover's list says it: "waiting 2m",
// "changes · 11m", "ok · 4m", "answered · 4m", "no answer expected",
// "not sent", then what chi did with the answer's message (+words+, the
// server's: "held · peer turns", "read", "completed"); +kind+ its tint.
// @return {text, kind}
export function exchangeState(ex, now = Date.now(), words = null) {
  if (ex.state === "failed") return { text: "not sent", kind: "failed" };
  if (ex.state === "none_expected") return { text: "no answer expected", kind: "none" };
  if (ex.state === "waiting") {
    const age = since(ex.at, now);
    return { text: age === null ? "waiting" : `waiting ${spanText(age)}`, kind: "waiting" };
  }
  const took = ex.id && ex.answer?.at ? since(ex.at, Date.parse(ex.answer.at)) : null;
  const verdict = verdictWord(ex.answer?.verdict);
  const word = verdict || "answered";
  const text = [took === null ? word : `${word} · ${spanText(took)}`, words].filter(Boolean).join(" · ");
  return { text, kind: verdict || "answered" };
}

// The popover's inside for +group+ (scene 2). +exchanges+ newest first;
// +text+ the newest message's text once View latest answer read it (null
// before); +status+ the status card's command ("/claude") when the session
// has it, else null; +drawn+(id) whether that send's row is in the
// conversation (its list row then jumps to it).
export function peerPopoverTemplate(group, exchanges = [], { text = null, status = null, drawn = () => false, now = Date.now() } = {}) {
  const peer = group.peer || {};
  const messages = messagesOf(group);
  const words = new Map(messages.map((m) => [String(m.serial), m.words]));
  const all = sends(exchanges);
  const lastSent = all.find((ex) => ex.state !== "failed");
  const failing = peer.can_send && cantSend(group, exchanges);
  const sendsLine = !peer.can_send
    ? "can't: it paired with no address chi can reach"
    : failing
      ? `the last send didn't go through: pair again from ${group.label}`
      : [`to ${peer.address}`, lastSent ? `last sent ${wallClock(lastSent.at, now)}` : ""].filter(Boolean).join(" · ");
  const answersLine = messages.length ? `with chi peer say · last ${wallClock(messages[0].at, now)}` : "nothing yet";
  const list = (exchanges || []).filter((ex) => ex?.id || ex?.answer).slice(0, POPOVER_EXCHANGES);
  const rowInside = (ex) => {
    const serial = ex.answer?.serial;
    const state = exchangeState(ex, now, serial === undefined || serial === null ? null : words.get(String(serial)));
    const what = ex.id ? [ex.kind, ex.title].filter(Boolean).join(" · ") || "a send"
      : [`#${serial ?? "?"}`, ex.answer?.summary].filter(Boolean).join(" · ");
    return html`<span class="pp-x-at">${wallClock(ex.id ? ex.at : ex.answer?.at || ex.at, now)}</span><span class="pp-x-what">${
      what}</span><span class=${`pp-x-state ${state.kind}`}>${state.text}</span>`;
  };
  return html`<div class="ctx-pop-head"><strong>${group.label}</strong
    ><span class="ctx-pop-kind">paired peer</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class="peer-pop-legs"><div><span>chi sends</span><span class=${failing ? "warn" : ""}>${sendsLine}</span></div
    ><div><span>it answers</span><span>${answersLine}</span></div></div
    >${list.length ? html`<div class="peer-pop-list"><div class="peer-pop-list-head">Exchanges</div>${list.map((ex) => (ex.id && drawn(ex.id)
      ? html`<button type="button" class="peer-pop-x" data-act="jump" data-peer-id=${ex.id}>${rowInside(ex)}</button>`
      : html`<div class="peer-pop-x">${rowInside(ex)}</div>`))}</div>` : nothing
    }<pre class="ctx-pop-text" ?hidden=${text === null}>${text ?? ""}</pre
    ><div class="ctx-pop-actions">${messages.length && text === null ? html`<button type="button" data-act="view">View latest answer</button>` : nothing
    }${status ? html`<button type="button" data-act="status">Status card (${status})</button>` : nothing
    }<button type="button" class="ctx-pop-detach" data-act="unpair" title="End the pairing (its messages stay)">Unpair</button></div>`;
}

// The peer's status card command ("/claude") when the session's commands
// (the session GET's `commands`) have it, else null.
export function peerStatusCommand(commands, name) {
  const line = `/${name}`;
  return (Array.isArray(commands) ? commands : []).some((c) => c?.name === line) ? line : null;
}
