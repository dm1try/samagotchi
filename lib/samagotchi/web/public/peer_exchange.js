// A peer exchange as the conversation shows it (docs/internals/web-frontend.md,
// The peer exchange): a send row's peer ref, the exchange's state as words
// ("waiting 2m", "changes · answered after 6m") and the send row's pill. Pure:
// no fetch, no DOM; the state and the verdict come from the server
// (GET …/peers: PeerExchanges.joined), never joined or parsed here.
// Its own module: new exports go in new modules (web-frontend.md).

import { html, nothing } from "./vendor/lit-html.js";

// The ref of kind peer on a tool row (a peer tool's send: Plugin::Peer's
// refs, {kind: "peer", target: {id}}), or null.
export function peerRef(row) {
  const refs = Array.isArray(row?.refs) ? row.refs : [];
  return refs.find((ref) => ref?.kind === "peer" && typeof ref.target?.id === "string" && ref.target.id) || null;
}

// A stretch of time as the pill says it: "<1m", "6m", "2h", "3d".
export function spanText(ms) {
  const s = Math.max(0, Math.floor(Number(ms) / 1000) || 0);
  if (s < 60) return "<1m";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

const since = (from, to) => {
  const a = Date.parse(from || "");
  const b = typeof to === "number" ? to : Date.parse(to || "");
  return Number.isNaN(a) || Number.isNaN(b) ? null : b - a;
};

// The verdict word of an answer (the server's, one of OK, CHANGES,
// UNSURE), lower case; "" for none.
export function verdictWord(verdict) {
  return ["OK", "CHANGES", "UNSURE"].includes(verdict) ? verdict.toLowerCase() : "";
}

// The exchange's state in words. +ended+: the row's turn has ended (a row
// whose id has no exchange then reads "not sent": the send never went out);
// +short+: the phone's words. "" when there is nothing to say (a context
// send expects no answer; an exchange not read yet in a running turn).
export function stateText(exchange, { now = Date.now(), short = false, ended = false } = {}) {
  if (!exchange) return ended ? "not sent" : "";
  if (exchange.state === "failed") return "not sent";
  if (exchange.state === "none_expected") return "";
  if (exchange.state === "waiting") {
    const age = since(exchange.at, now);
    return age === null ? "waiting" : `waiting ${spanText(age)}`;
  }
  if (exchange.state !== "answered") return "";
  const took = since(exchange.at, exchange.answer?.at);
  const verdict = verdictWord(exchange.answer?.verdict);
  const after = took === null ? "" : `after ${spanText(took)}`;
  if (!verdict) return after ? `answered ${after}` : "answered";
  if (short) return after ? `${verdict} · ${after}` : verdict;
  return after ? `${verdict} · answered ${after}` : `${verdict} · answered`;
}

// The pill's tint: the verdict's for an answer, else the state's.
function pillKind(exchange, text) {
  if (!exchange) return text ? "failed" : "";
  if (exchange.state === "answered") return verdictWord(exchange.answer?.verdict) || "answered";
  return exchange.state;
}

// The send row's pill: a button that jumps to the answer (↓) once answered,
// a span otherwise, nothing when stateText has no words. Its long and short
// words both drawn (CSS shows the phone's under 600 px). +title+: the row's
// output text (its output line is hidden on a send that went out).
export function pillTemplate(exchange, { now = Date.now(), ended = false, title = "" } = {}) {
  const long = stateText(exchange, { now, ended });
  if (!long) return nothing;
  const short = stateText(exchange, { now, ended, short: true });
  const cls = `peer-state ${pillKind(exchange, long)}`;
  const words = short === long
    ? html`<span class="peer-long">${long}</span>`
    : html`<span class="peer-long">${long}</span><span class="peer-short">${short}</span>`;
  if (exchange?.state === "answered") {
    return html`<button type="button" class=${cls} data-peer-jump="answer" title=${title || nothing}
      aria-label=${`${long}: go to the answer`}>${words}<span aria-hidden="true"> ↓</span></button>`;
  }
  return html`<span class=${cls} title=${title || nothing}>${words}</span>`;
}
