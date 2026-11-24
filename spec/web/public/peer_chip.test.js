// A paired peer's one chip (peer_chip.js): fed by the peers model (GET
// …/peers: the mailbox) alone: the groups, each state and their order, the
// popover's rows and texts with what chi did with each message, and no
// exchanges (an older chi web, a peer the read doesn't name).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import {
  exchangeState, peerChipModel, peerGroups, peerKey, peerPopoverTemplate, peerStatusCommand,
} from "../../../lib/samagotchi/web/public/peer_chip.js";
import { wallClock } from "../../../lib/samagotchi/web/public/format.js";

const NOW = Date.parse("2026-11-20T14:11:00Z");
const ago = (min) => new Date(NOW - min * 60_000).toISOString();
const message = (serial, min, receipt = null, over = {}) => ({ serial, summary: `answer ${serial}`, re: null, at: ago(min), wake: true,
  receipt, words: receipt ? receipt.words : "unread", ...over });
const peerRow = (over = {}) => ({ name: "claude", label: "Claude", paired_at: ago(30), from: "Claude Code in /r",
  address: "/tmp/c.sock", can_send: true, messages: [], exchanges: [], ...over });
const group = (over = {}) => peerGroups([peerRow(over)])[0];
const send = (id, kind, title, min, state, answer = null) => ({ id, kind, title, at: ago(min), state, ...(answer ? { answer } : {}) });
const drawn = (template) => {
  const div = document.createElement("div");
  render(template, div);
  return div;
};

test("peerGroups: one group per paired peer of the model, in its order; an unpaired one (messages kept) has none", () => {
  const groups = peerGroups([peerRow(), peerRow({ name: "codex", label: "Codex", can_send: false, address: null }),
                             peerRow({ name: "gone", label: "Gone", paired_at: null, messages: [message(1, 2)] })]);
  assert.deepEqual(groups.map((g) => [g.key, g.name, g.label]), [["peer:claude", "claude", "Claude"], ["peer:codex", "codex", "Codex"]]);
  assert.equal(peerKey("claude"), "peer:claude");
  assert.deepEqual(peerGroups(undefined), []);
});

test("peerChipModel: each state's words, and the first that applies wins", () => {
  const label = (g, exchanges) => peerChipModel(g, exchanges, NOW).label;
  const failed = send("s3", "validate", "c", 1, "failed");
  const waiting = send("s2", "validate", "b", 2, "waiting");
  const answered = send("s1", "question", "a", 20, "answered", { at: ago(16), verdict: "OK", serial: 1 });
  const read = { state: "ended", outcome: "completed", words: "completed" };
  // paired: nothing sent, or the round closed and its message read.
  assert.equal(label(group(), []), "Claude · paired");
  assert.equal(label(group({ messages: [message(1, 16, read)] }), [answered]), "Claude · paired");
  // waiting: the newest validate/question has no answer; the age is the send's.
  assert.equal(label(group(), [waiting, answered]), "Claude · waiting 2m");
  assert.equal(label(group(), [send("s4", "context", "x", 1, "none_expected"), waiting]), "Claude · waiting 2m");
  // can't send: the newest send failed, over waiting.
  assert.equal(label(group(), [failed, waiting]), "Claude · can't send");
  // answered: its newest message no turn read (none, held, noted), its age the message's, with the dot.
  for (const receipt of [null, { state: "held", reason: "peer_turns", words: "held · peer turns" }, { state: "noted", words: "noted" }]) {
    const m = peerChipModel(group({ messages: [message(2, 3, receipt), message(1, 16, read)] }), [answered], NOW);
    assert.deepEqual([m.label, m.state, m.dot], ["Claude · answered 3m", "answered", true]);
  }
  // read, woke or ended: no dot.
  for (const state of ["read", "woke", "ended"]) {
    assert.equal(peerChipModel(group({ messages: [message(2, 3, { state })] }), [], NOW).state, "paired");
  }
  // waiting wins over an unread message; can't send over both.
  const unread = group({ messages: [message(2, 3)] });
  assert.equal(label(unread, [waiting]), "Claude · waiting 2m");
  assert.equal(label(unread, [failed]), "Claude · can't send");
  // answers only: a pairing with no address, whatever else.
  const remote = peerGroups([peerRow({ name: "codex", label: "Codex", can_send: false, address: null, messages: [message(1, 1)] })])[0];
  const r = peerChipModel(remote, [failed], NOW);
  assert.deepEqual([r.label, r.state, r.dot, r.key, r.name, r.peer], ["Codex · answers only", "answers-only", false, "peer:codex", "peer:codex", true]);
  assert.equal(r.title, "paired with no address chi can reach: it answers, chi can't send to it");
});

test("no exchanges (an older chi web, a send not in the list): never can't send", () => {
  assert.equal(peerChipModel(group(), [], NOW).state, "paired");
  // An unclaimed answer is no send: it doesn't make the chip wait or fail.
  assert.equal(peerChipModel(group(), [{ id: null, at: ago(1), state: "answered", answer: { at: ago(1) } }], NOW).state, "paired");
});

test("exchangeState: the list's words and tints, then what chi did with the answer's message", () => {
  const words = (ex, w = null) => Object.values(exchangeState(ex, NOW, w));
  assert.deepEqual(words(send("a", "validate", "t", 2, "waiting")), ["waiting 2m", "waiting"]);
  assert.deepEqual(words(send("a", "validate", "t", 22, "answered", { at: ago(11), verdict: "CHANGES" })), ["changes · 11m", "changes"]);
  assert.deepEqual(words(send("a", "validate", "t", 22, "answered", { at: ago(11), verdict: "CHANGES" }), "held · peer turns"),
                   ["changes · 11m · held · peer turns", "changes"]);
  assert.deepEqual(words(send("a", "validate", "t", 8, "answered", { at: ago(4), verdict: "OK" }), "completed"), ["ok · 4m · completed", "ok"]);
  assert.deepEqual(words(send("a", "question", "t", 8, "answered", { at: ago(4) }), "read"), ["answered · 4m · read", "answered"]);
  assert.deepEqual(words(send("a", "context", "t", 8, "none_expected")), ["no answer expected", "none"]);
  assert.deepEqual(words(send("a", "validate", "t", 8, "failed")), ["not sent", "failed"]);
});

test("peerPopoverTemplate: the head, the two ways, the exchanges newest first with the receipts' words, the actions", () => {
  const messages = [message(3, 9, { state: "held", reason: "peer_turns", words: "held · peer turns" }), message(2, 25, { state: "read", words: "read" })];
  const exchanges = [
    send("s4", "validate", "Bridge item route, phase A", 2, "waiting"),
    send("s3", "validate", "turn-id guard plan step 2", 20, "answered", { at: ago(9), verdict: "CHANGES", serial: 3 }),
    { id: null, at: ago(25), state: "answered", answer: { at: ago(25), serial: 2, summary: "sync: API moved" } },
    send("s2", "context", "chi's last answer", 31, "none_expected"),
  ];
  const el = drawn(peerPopoverTemplate(group({ messages }), exchanges, { status: "/claude", drawn: (id) => id === "s3", now: NOW }));
  const text = (sel) => el.querySelector(sel)?.textContent;
  assert.equal(text(".ctx-pop-head strong"), "Claude");
  assert.equal(text(".ctx-pop-kind"), "paired peer");
  const legs = [...el.querySelectorAll(".peer-pop-legs > div")].map((d) => [...d.children].map((s) => s.textContent).join(" "));
  assert.deepEqual(legs, [`chi sends to /tmp/c.sock · last sent ${wallClock(ago(2), NOW)}`,
                          `it answers with chi peer say · last ${wallClock(ago(9), NOW)}`]);
  const rows = [...el.querySelectorAll(".peer-pop-x")];
  assert.deepEqual(rows.map((r) => [r.tagName, r.querySelector(".pp-x-what").textContent, r.querySelector(".pp-x-state").textContent]), [
    ["DIV", "validate · Bridge item route, phase A", "waiting 2m"],
    ["BUTTON", "validate · turn-id guard plan step 2", "changes · 11m · held · peer turns"],
    ["DIV", "#2 · sync: API moved", "answered · read"],
    ["DIV", "context · chi's last answer", "no answer expected"],
  ]);
  // Only a drawn send's row jumps, by its id.
  assert.equal(rows[1].dataset.act, "jump");
  assert.equal(rows[1].dataset.peerId, "s3");
  assert.deepEqual([...el.querySelectorAll(".ctx-pop-actions button")].map((b) => [b.dataset.act, b.textContent]),
                   [["view", "View latest answer"], ["status", "Status card (/claude)"], ["unpair", "Unpair"]]);
  assert.equal(el.querySelector('[data-act="unpair"]').title, "End the pairing (its messages stay)");
  assert.equal(el.querySelector(".ctx-pop-text").hidden, true);
});

test("peerPopoverTemplate: answers only, a failed last send, no status command, the text read, nothing yet", () => {
  const remote = peerGroups([peerRow({ name: "codex", label: "Codex", can_send: false, address: null })])[0];
  const a = drawn(peerPopoverTemplate(remote, [], { now: NOW }));
  assert.equal(a.querySelector(".peer-pop-legs > div > span:last-child").textContent, "can't: it paired with no address chi can reach");
  assert.ok(a.querySelector(".peer-pop-list") === null);
  assert.ok(a.querySelector('[data-act="status"]') === null);
  assert.ok(a.querySelector('[data-act="view"]') === null);
  assert.equal(a.querySelectorAll(".peer-pop-legs > div > span:last-child")[1].textContent, "nothing yet");
  const f = drawn(peerPopoverTemplate(group(), [send("s5", "validate", "t", 1, "failed")], { now: NOW }));
  const sends = f.querySelector(".peer-pop-legs > div > span:last-child");
  assert.deepEqual([sends.textContent, sends.className], ["the last send didn't go through: pair again from Claude", "warn"]);
  assert.equal(f.querySelector(".pp-x-state").textContent, "not sent");
  const t = drawn(peerPopoverTemplate(group({ messages: [message(1, 2)] }), [], { text: "VERDICT OK", now: NOW }));
  assert.equal(t.querySelector(".ctx-pop-text").hidden, false);
  assert.equal(t.querySelector(".ctx-pop-text").textContent, "VERDICT OK");
  assert.ok(t.querySelector('[data-act="view"]') === null);
});

test("peerStatusCommand: the peer's command when the session lists it", () => {
  assert.equal(peerStatusCommand([{ name: "/help" }, { name: "/claude" }], "claude"), "/claude");
  assert.equal(peerStatusCommand([{ name: "/help" }], "claude"), null);
  assert.equal(peerStatusCommand(undefined, "claude"), null);
});

test("can't send ends once the peer pairs again: a pairing newer than the failed send", () => {
  const failed = [send("s3", "validate", "c", 5, "failed")];
  assert.equal(peerChipModel(group({ paired_at: ago(9) }), failed, NOW).state, "cant-send");
  const again = group({ paired_at: ago(1) });
  assert.equal(peerChipModel(again, failed, NOW).label, "Claude · paired");
  const el = drawn(peerPopoverTemplate(again, failed, { now: NOW }));
  const sends = el.querySelector(".peer-pop-legs > div > span:last-child");
  assert.deepEqual([sends.textContent, sends.className], ["to /tmp/c.sock", ""]);
  // The list still says that send didn't go out.
  assert.equal(el.querySelector(".pp-x-state").textContent, "not sent");
});
