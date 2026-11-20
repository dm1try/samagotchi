// A peer exchange's words and the send row's pill (peer_exchange.js).
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { peerRef, pillTemplate, spanText, stateText } from "../../../lib/samagotchi/web/public/peer_exchange.js";

const SENT = "2026-11-20T10:00:00Z";
const now = Date.parse("2026-11-20T10:02:30Z");
const answered = (verdict, mins = 6) => ({
  id: "s-ab12cd", kind: "validate", title: "phase A", at: SENT, state: "answered",
  answer: { summary: "phase A: VERDICT x", at: new Date(Date.parse(SENT) + mins * 60_000).toISOString(), serial: 3, ...(verdict ? { verdict } : {}) },
});

test("peerRef: the row's ref of kind peer, else null", () => {
  const ref = { kind: "peer", target: { id: "s-ab12cd" }, label: "Claude · validate" };
  assert.equal(peerRef({ refs: [{ kind: "file", target: { path: "a" } }, ref] }), ref);
  assert.equal(peerRef({ refs: [{ kind: "file", target: { path: "a" } }] }), null);
  assert.equal(peerRef({ refs: [{ kind: "peer", target: {} }] }), null);
  assert.equal(peerRef({}), null);
  assert.equal(peerRef(null), null);
});

test("spanText: under a minute, minutes, hours, days", () => {
  assert.equal(spanText(20_000), "<1m");
  assert.equal(spanText(6 * 60_000), "6m");
  assert.equal(spanText(3 * 3600_000), "3h");
  assert.equal(spanText(2 * 86400_000), "2d");
});

test("stateText: waiting, each verdict long and short, no verdict, failed, a context send, none", () => {
  assert.equal(stateText({ state: "waiting", at: SENT }, { now }), "waiting 2m");
  assert.equal(stateText({ state: "waiting", at: SENT }, { now, short: true }), "waiting 2m");
  assert.equal(stateText(answered("CHANGES"), { now }), "changes · answered after 6m");
  assert.equal(stateText(answered("CHANGES"), { now, short: true }), "changes · after 6m");
  assert.equal(stateText(answered("OK", 4), { now }), "ok · answered after 4m");
  assert.equal(stateText(answered("UNSURE"), { now, short: true }), "unsure · after 6m");
  assert.equal(stateText(answered(null), { now }), "answered after 6m");
  assert.equal(stateText(answered(null), { now, short: true }), "answered after 6m");
  assert.equal(stateText({ state: "failed", at: SENT, error: "gone" }, { now }), "not sent");
  assert.equal(stateText({ state: "none_expected", at: SENT }, { now }), "");
  // No exchange for the row's id: nothing while its turn runs, "not sent" once it ended.
  assert.equal(stateText(null, { now }), "");
  assert.equal(stateText(null, { now, ended: true }), "not sent");
});

test("pillTemplate: an answered send is a button to its answer (↓), its title the row's output; else a span", () => {
  const pill = markupOf(pillTemplate(answered("CHANGES"), { now, title: "sent to Claude: validate · phase A" }));
  assert.match(pill, /^<button type="button" data-peer-jump="answer" class="peer-state changes" title="sent to Claude: validate · phase A"/);
  assert.match(pill, /<span class="peer-long">changes · answered after 6m<\/span><span class="peer-short">changes · after 6m<\/span>/);
  assert.match(pill, /↓/);
  const waiting = markupOf(pillTemplate({ state: "waiting", at: SENT }, { now }));
  assert.equal(waiting, '<span class="peer-state waiting"><span class="peer-long">waiting 2m</span></span>');
  assert.match(markupOf(pillTemplate(null, { now, ended: true })), /class="peer-state failed".*not sent/);
  assert.equal(markupOf(pillTemplate(null, { now })), "");
  assert.equal(markupOf(pillTemplate({ state: "none_expected", at: SENT }, { now })), "");
});
