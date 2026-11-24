// The peer chip's two mailbox calls (peer_mailbox_api.js): their routes and methods.
import test from "node:test";
import assert from "node:assert/strict";
import { getPeerMessage, unpairPeer } from "../../../lib/samagotchi/web/public/peer_mailbox_api.js";

const recording = () => {
  const calls = [];
  const fetchImpl = async (path, opts) => {
    calls.push([opts.method || "GET", path]);
    return { ok: true, status: 200, json: async () => ({ ok: true }) };
  };
  return { calls, fetchImpl };
};

test("a message by its number, and Unpair as a DELETE of the peer", async () => {
  const r = recording();
  await getPeerMessage("s 1", "claude", 12, { fetchImpl: r.fetchImpl });
  await unpairPeer("s 1", "claude", { fetchImpl: r.fetchImpl });
  assert.deepEqual(r.calls, [["GET", "/api/sessions/s%201/peers/claude/messages/12"], ["DELETE", "/api/sessions/s%201/peers/claude"]]);
});
