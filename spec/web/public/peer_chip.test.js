// A paired peer's one chip (peer_chip.js): the grouping, each state and
// their order, the popover's rows and texts, and no exchanges (an older chi
// web, a peer the read doesn't name).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import {
  exchangeState, peerChipModel, peerGroups, peerKey, peerPopoverTemplate, peerShown, peerStatusCommand,
} from "../../../lib/samagotchi/web/public/peer_chip.js";
import { wallClock } from "../../../lib/samagotchi/web/public/format.js";

const NOW = Date.parse("2026-11-20T14:11:00Z");
const ago = (min) => new Date(NOW - min * 60_000).toISOString();
const leg = (peer, which, over = {}) => ({ name: `${peer}-${which}`, scope: "session", kind: "push", peer, leg: which,
  label: peer[0].toUpperCase() + peer.slice(1), has_text: which === "outbox", unread: false, muted: false,
  fetched_at: ago(9), summary: "", ...over });
const ci = { name: "ci", scope: "session", kind: "cmd", has_text: true, fetched_at: ago(1) };
const group = (over = {}) => peerGroups([leg("claude", "inbox", over.inbox), leg("claude", "outbox", over.outbox)]).peers[0];
const send = (id, kind, title, min, state, answer = null) => ({ id, kind, title, at: ago(min), state, ...(answer ? { answer } : {}) });
const drawn = (template) => {
  const div = document.createElement("div");
  render(template, div);
  return div;
};

test("peerGroups: a peer's two legs one group, in the order its first leg comes; the rest as they were", () => {
  const { peers, rest } = peerGroups([ci, leg("claude", "outbox"), leg("codex", "outbox"), leg("claude", "inbox"),
                                      { name: "odd", peer: "x", leg: "side" }]);
  assert.deepEqual(peers.map((g) => [g.key, g.name, g.label, g.inbox?.name ?? null, g.outbox?.name ?? null]),
                   [["peer:claude", "claude", "Claude", "claude-inbox", "claude-outbox"], ["peer:codex", "codex", "Codex", null, "codex-outbox"]]);
  assert.deepEqual(rest.map((r) => r.name), ["ci", "odd"]);
  assert.equal(peerKey("claude"), "peer:claude");
});

test("a muted leg stays in the group but counts as absent; a group with both muted isn't shown", () => {
  const g = group({ inbox: { muted: true } });
  assert.equal(g.inbox.name, "claude-inbox");
  assert.equal(peerChipModel(g, [], NOW).state, "answers-only");
  assert.equal(peerShown(g), true);
  assert.equal(peerShown(group({ inbox: { muted: true }, outbox: { muted: true } })), false);
});

test("peerChipModel: each state's words, and the first that applies wins", () => {
  const label = (g, exchanges) => peerChipModel(g, exchanges, NOW).label;
  const failed = send("s3", "validate", "c", 1, "failed");
  const waiting = send("s2", "validate", "b", 2, "waiting");
  const answered = send("s1", "question", "a", 20, "answered", { at: ago(16), verdict: "OK" });
  // paired: nothing sent, or the round closed.
  assert.equal(label(group(), []), "Claude · paired");
  assert.equal(label(group(), [answered]), "Claude · paired");
  // waiting: the newest validate/question has no answer; the age is the send's.
  assert.equal(label(group(), [waiting, answered]), "Claude · waiting 2m");
  // a context send after it expects nothing: still waiting on the validate.
  assert.equal(label(group(), [send("s4", "context", "x", 1, "none_expected"), waiting]), "Claude · waiting 2m");
  // can't send: the newest send failed, over waiting.
  assert.equal(label(group(), [failed, waiting]), "Claude · can't send");
  // answered: the outbox unread, its age the text's, with the dot.
  const unread = group({ outbox: { unread: true, fetched_at: ago(3) } });
  const m = peerChipModel(unread, [answered], NOW);
  assert.deepEqual([m.label, m.state, m.dot], ["Claude · answered 3m", "answered", true]);
  // waiting wins over an unread outbox; can't send over both.
  assert.equal(label(unread, [waiting]), "Claude · waiting 2m");
  assert.equal(label(unread, [failed]), "Claude · can't send");
  // answers only: no inbox, whatever else.
  const remote = peerGroups([leg("codex", "outbox", { unread: true })]).peers[0];
  const r = peerChipModel(remote, [failed], NOW);
  assert.deepEqual([r.label, r.state, r.dot, r.key, r.name, r.peer], ["Codex · answers only", "answers-only", false, "peer:codex", "peer:codex", true]);
  assert.equal(r.title, "no inbox attached here: it answers, chi can't send to it");
});

test("no exchanges (an older chi web, a peer the read doesn't name, a send not in the list): never can't send", () => {
  assert.equal(peerChipModel(group(), [], NOW).state, "paired");
  // An unclaimed answer is no send: it doesn't make the chip wait or fail.
  assert.equal(peerChipModel(group(), [{ id: null, at: ago(1), state: "answered", answer: { at: ago(1) } }], NOW).state, "paired");
});

test("exchangeState: the list's words and tints", () => {
  const words = (ex) => Object.values(exchangeState(ex, NOW));
  assert.deepEqual(words(send("a", "validate", "t", 2, "waiting")), ["waiting 2m", "waiting"]);
  assert.deepEqual(words(send("a", "validate", "t", 22, "answered", { at: ago(11), verdict: "CHANGES" })), ["changes · 11m", "changes"]);
  assert.deepEqual(words(send("a", "validate", "t", 8, "answered", { at: ago(4), verdict: "OK" })), ["ok · 4m", "ok"]);
  assert.deepEqual(words(send("a", "question", "t", 8, "answered", { at: ago(4) })), ["answered · 4m", "answered"]);
  assert.deepEqual(words(send("a", "context", "t", 8, "none_expected")), ["no answer expected", "none"]);
  assert.deepEqual(words(send("a", "validate", "t", 8, "failed")), ["not sent", "failed"]);
});

test("peerPopoverTemplate: the head, the two ways, the exchanges newest first, the actions", () => {
  const exchanges = [
    send("s4", "validate", "Bridge item route, phase A", 2, "waiting"),
    send("s3", "validate", "turn-id guard plan step 2", 20, "answered", { at: ago(9), verdict: "CHANGES" }),
    { id: null, at: ago(25), state: "answered", answer: { at: ago(25) } },
    send("s2", "context", "chi's last answer", 31, "none_expected"),
  ];
  const el = drawn(peerPopoverTemplate(group(), exchanges, { status: "/claude", drawn: (id) => id === "s3", now: NOW }));
  const text = (sel) => el.querySelector(sel)?.textContent;
  assert.equal(text(".ctx-pop-head strong"), "Claude");
  assert.equal(text(".ctx-pop-kind"), "paired peer");
  const legs = [...el.querySelectorAll(".peer-pop-legs > div")].map((d) => [...d.children].map((s) => s.textContent).join(" "));
  assert.deepEqual(legs, [`chi sends to its inbox (claude-inbox) · last sent ${wallClock(ago(2), NOW)}`,
                          `it answers into claude-outbox · last ${wallClock(ago(9), NOW)}`]);
  const rows = [...el.querySelectorAll(".peer-pop-x")];
  assert.deepEqual(rows.map((r) => [r.tagName, r.querySelector(".pp-x-what").textContent, r.querySelector(".pp-x-state").textContent]), [
    ["DIV", "validate · Bridge item route, phase A", "waiting 2m"],
    ["BUTTON", "validate · turn-id guard plan step 2", "changes · 11m"],
    ["DIV", "context · chi's last answer", "no answer expected"],
  ]);
  // Only a drawn send's row jumps, by its id.
  assert.equal(rows[1].dataset.act, "jump");
  assert.equal(rows[1].dataset.peerId, "s3");
  assert.deepEqual([...el.querySelectorAll(".ctx-pop-actions button")].map((b) => [b.dataset.act, b.textContent]),
                   [["view", "View latest answer"], ["status", "Status card (/claude)"], ["unpair", "Unpair"]]);
  assert.equal(el.querySelector(".ctx-pop-text").hidden, true);
});

test("peerPopoverTemplate: answers only, a failed last send, no status command, the text read, no exchanges", () => {
  const remote = peerGroups([leg("codex", "outbox")]).peers[0];
  const a = drawn(peerPopoverTemplate(remote, [], { now: NOW }));
  assert.equal(a.querySelector(".peer-pop-legs > div > span:last-child").textContent, "can't: no inbox attached here");
  assert.ok(a.querySelector(".peer-pop-list") === null);
  assert.ok(a.querySelector('[data-act="status"]') === null);
  assert.equal(a.querySelector('[data-act="unpair"]').title, "Detach codex-outbox");
  const f = drawn(peerPopoverTemplate(group(), [send("s5", "validate", "t", 1, "failed")], { now: NOW }));
  const sends = f.querySelector(".peer-pop-legs > div > span:last-child");
  assert.deepEqual([sends.textContent, sends.className], ["the last send didn't go through: pair again from Claude", "warn"]);
  assert.equal(f.querySelector(".pp-x-state").textContent, "not sent");
  const t = drawn(peerPopoverTemplate(group(), [], { text: "VERDICT OK", now: NOW }));
  assert.equal(t.querySelector(".ctx-pop-text").hidden, false);
  assert.equal(t.querySelector(".ctx-pop-text").textContent, "VERDICT OK");
  assert.ok(t.querySelector('[data-act="view"]') === null);
  // No text in the outbox yet: nothing to view.
  const empty = drawn(peerPopoverTemplate(group({ outbox: { has_text: false, fetched_at: null } }), [], { now: NOW }));
  assert.ok(empty.querySelector('[data-act="view"]') === null);
  assert.equal(empty.querySelectorAll(".peer-pop-legs > div > span:last-child")[1].textContent, "into claude-outbox · nothing yet");
});

test("peerStatusCommand: the peer's command when the session lists it", () => {
  assert.equal(peerStatusCommand([{ name: "/help" }, { name: "/claude" }], "claude"), "/claude");
  assert.equal(peerStatusCommand([{ name: "/help" }], "claude"), null);
  assert.equal(peerStatusCommand(undefined, "claude"), null);
});

test("can't send ends once the peer pairs again: the inbox pushed after the failed send", () => {
  const failed = [send("s3", "validate", "c", 5, "failed")];
  assert.equal(peerChipModel(group({ inbox: { fetched_at: ago(9) } }), failed, NOW).state, "cant-send");
  const again = group({ inbox: { fetched_at: ago(1) } });
  assert.equal(peerChipModel(again, failed, NOW).label, "Claude · paired");
  const el = drawn(peerPopoverTemplate(again, failed, { now: NOW }));
  const sends = el.querySelector(".peer-pop-legs > div > span:last-child");
  assert.deepEqual([sends.textContent, sends.className], ["to its inbox (claude-inbox)", ""]);
  // The list still says that send didn't go out.
  assert.equal(el.querySelector(".pp-x-state").textContent, "not sent");
});
