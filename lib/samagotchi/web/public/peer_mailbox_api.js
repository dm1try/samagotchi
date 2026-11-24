// A session's peer mailbox through chi web, for the peer chip
// (context_chips.js): one message's text, and Unpair. Owner only (chi web's
// …/peers routes). docs/internals/web-frontend.md, The peer exchange.
// Its own module: new exports go in new modules (web-frontend.md).

import { api } from "./data.js";

const base = (id, name) => `/api/sessions/${encodeURIComponent(id)}/peers/${encodeURIComponent(name)}`;

// GET …/peers/NAME/messages/SERIAL → {serial, text, summary, re, at, wake, receipt}.
export function getPeerMessage(id, name, serial, box = null, opts = {}) {
  if (box && typeof box === "object") { opts = box; box = null; }
  const query = box ? `?box=${encodeURIComponent(box)}` : "";
  return api(`${base(id, name)}/messages/${encodeURIComponent(serial)}${query}`, opts);
}

// DELETE …/peers/NAME (Unpair) → {unpaired}: the pairing ends, its messages stay.
export function unpairPeer(id, name, opts = {}) {
  return api(base(id, name), { ...opts, method: "DELETE" });
}
