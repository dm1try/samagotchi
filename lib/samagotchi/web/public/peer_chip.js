// A paired peer in the session bar: its two context sources (<name>-inbox,
// <name>-outbox) drawn as one chip that says how the pairing stands
// (paired, waiting, answered, can't send, answers only), and that chip's
// popover (how chi and the peer reach each other, the last exchanges, View
// latest answer, Status card, Unpair). Pure templates and models: the
// chips' controller (context_chips.js) draws them, the exchanges are the
// peers model's (peer_data.js, GET …/peers). docs/internals/web-frontend.md,
// The peer exchange. Its own module: new exports go in new modules.

import { html, nothing } from "./vendor/lit-html.js";
import { spanText, verdictWord } from "./peer_exchange.js";
import { wallClock } from "./format.js";

// A peer chip's key among the chips ("peer:claude"); an ordinary chip's is
// its source's name, which never holds a ":" (ContextSources' names).
export const peerKey = (name) => `peer:${name}`;

// How many exchanges the popover lists (the newest).
export const POPOVER_EXCHANGES = 8;

// GET …/context's rows split: the peer sources (a row with `peer` and its
// `leg`) grouped per peer, {key, name, label, inbox, outbox} (a leg's row
// or null; a muted leg stays in its group), in the order their first leg
// comes; and the rest, the ordinary rows, as they were.
export function peerGroups(rows) {
  const peers = new Map();
  const rest = [];
  for (const row of rows || []) {
    if (!row) continue;
    if (!row.peer || !["inbox", "outbox"].includes(row.leg)) {
      rest.push(row);
      continue;
    }
    let group = peers.get(row.peer);
    if (!group) {
      group = { key: peerKey(row.peer), name: row.peer, label: row.label || row.peer, inbox: null, outbox: null };
      peers.set(row.peer, group);
    }
    group[row.leg] = row;
  }
  return { peers: [...peers.values()], rest };
}

// A leg that counts: there and not muted.
const live = (leg) => (leg && !leg.muted ? leg : null);
// The group's legs as the chip reads them, and whether it shows at all
// (a group whose legs are all muted is gone from the bar, as a muted row is).
export const peerShown = (group) => !!(live(group.inbox) || live(group.outbox));

// The sends among +exchanges+ (newest first): an unclaimed answer has no id.
const sends = (exchanges) => (exchanges || []).filter((ex) => ex?.id);
const ASKS = ["validate", "question"];

// The newest send failed and the peer hasn't paired again since: pairing
// again (the pair script) pushes the inbox, which moves its row's
// fetched_at past the failed send's time.
export function cantSend(group, exchanges) {
  const newest = sends(exchanges)[0];
  if (newest?.state !== "failed") return false;
  const paired = Date.parse(live(group.inbox)?.fetched_at || "");
  const failed = Date.parse(newest.at || "");
  return !(paired > failed);
}
const since = (iso, now) => {
  const at = Date.parse(iso || "");
  return Number.isNaN(at) ? null : now - at;
};

// The chip of +group+: the first state that applies.
// - answers-only: no inbox leg (a pairing through a remote: chi there can't send);
// - cant-send: the newest send failed (the transport refused it);
// - waiting: the newest validate or question send has no answer (its age the send's);
// - answered: the outbox has a text the agent hasn't read (its age the text's), with the dot;
// - paired otherwise.
// +exchanges+: the peer's from GET …/peers, newest first ([] when not read,
// an older chi web, a peer the read doesn't name: nothing then says failed).
// @return {key, name, state, label, title, dot}
export function peerChipModel(group, exchanges = [], now = Date.now()) {
  const inbox = live(group.inbox);
  const outbox = live(group.outbox);
  const all = sends(exchanges);
  const ask = all.find((ex) => ASKS.includes(ex.kind));
  let state = "paired";
  let words = "paired";
  let why = "paired: chi can send to it and it answers into its outbox";
  if (!inbox) {
    state = "answers-only";
    words = "answers only";
    why = "paired through a remote: it answers, chi here can't send to it";
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
  } else if (outbox?.unread && outbox.has_text) {
    const age = since(outbox.fetched_at, now);
    state = "answered";
    words = age === null ? "answered" : `answered ${spanText(age)}`;
    why = "an answer the agent hasn't read yet";
  }
  return { key: group.key, name: group.key, state, label: `${group.label} · ${words}`, title: why,
           dot: state === "answered", peer: true };
}

// An exchange's state as the popover's list says it: "waiting 2m",
// "changes · 11m", "ok · 4m", "answered · 4m", "no answer expected",
// "not sent"; +kind+ its tint.
// @return {text, kind}
export function exchangeState(ex, now = Date.now()) {
  if (ex.state === "failed") return { text: "not sent", kind: "failed" };
  if (ex.state === "none_expected") return { text: "no answer expected", kind: "none" };
  if (ex.state === "waiting") {
    const age = since(ex.at, now);
    return { text: age === null ? "waiting" : `waiting ${spanText(age)}`, kind: "waiting" };
  }
  const took = ex.answer?.at ? since(ex.at, Date.parse(ex.answer.at)) : null;
  const verdict = verdictWord(ex.answer?.verdict);
  const word = verdict || "answered";
  return { text: took === null ? word : `${word} · ${spanText(took)}`, kind: verdict || "answered" };
}

// The popover's inside for +group+ (scene 2). +exchanges+ newest first;
// +text+ the outbox's text once View latest answer read it (null before);
// +status+ the status card's command ("/claude") when the session has it,
// else null; +drawn+(id) whether that send's row is in the conversation
// (its list row then jumps to it).
export function peerPopoverTemplate(group, exchanges = [], { text = null, status = null, drawn = () => false, now = Date.now() } = {}) {
  const inbox = live(group.inbox);
  const outbox = live(group.outbox);
  const all = sends(exchanges);
  const lastSent = all.find((ex) => ex.state !== "failed");
  const sendsLine = !inbox
    ? "can't: paired through a remote"
    : cantSend(group, exchanges)
      ? `the last send didn't go through: pair again from ${group.label}`
      : [`to its inbox (${group.inbox.name})`, lastSent ? `last sent ${wallClock(lastSent.at, now)}` : ""].filter(Boolean).join(" · ");
  const answersLine = outbox
    ? [`into ${outbox.name}`, outbox.fetched_at ? `last ${wallClock(outbox.fetched_at, now)}` : "nothing yet"].join(" · ")
    : "no outbox attached";
  const list = all.slice(0, POPOVER_EXCHANGES);
  const rowInside = (ex) => {
    const state = exchangeState(ex, now);
    return html`<span class="pp-x-at">${wallClock(ex.at, now)}</span><span class="pp-x-what">${
      [ex.kind, ex.title].filter(Boolean).join(" · ") || "a send"}</span><span class=${`pp-x-state ${state.kind}`}>${state.text}</span>`;
  };
  const legs = [group.inbox, group.outbox].filter(Boolean);
  return html`<div class="ctx-pop-head"><strong>${group.label}</strong
    ><span class="ctx-pop-kind">paired peer</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class="peer-pop-legs"><div><span>chi sends</span><span class=${inbox && cantSend(group, exchanges) ? "warn" : ""}>${sendsLine}</span></div
    ><div><span>it answers</span><span>${answersLine}</span></div></div
    >${list.length ? html`<div class="peer-pop-list"><div class="peer-pop-list-head">Exchanges</div>${list.map((ex) => (drawn(ex.id)
      ? html`<button type="button" class="peer-pop-x" data-act="jump" data-peer-id=${ex.id}>${rowInside(ex)}</button>`
      : html`<div class="peer-pop-x">${rowInside(ex)}</div>`))}</div>` : nothing
    }<pre class="ctx-pop-text" ?hidden=${text === null}>${text ?? ""}</pre
    ><div class="ctx-pop-actions">${outbox?.has_text && text === null ? html`<button type="button" data-act="view">View latest answer</button>` : nothing
    }${status ? html`<button type="button" data-act="status">Status card (${status})</button>` : nothing
    }${legs.length ? html`<button type="button" class="ctx-pop-detach" data-act="unpair" title=${`Detach ${legs.map((l) => l.name).join(" and ")}`}>Unpair</button>` : nothing}</div>`;
}

// The peer's status card command ("/claude") when the session's commands
// (the session GET's `commands`) have it, else null.
export function peerStatusCommand(commands, name) {
  const line = `/${name}`;
  return (Array.isArray(commands) ? commands : []).some((c) => c?.name === line) ? line : null;
}
