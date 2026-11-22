// The peer exchange's controller (peer_links.js): the slots filled from the
// model, two rows of one id, the newest-answer rule, both jumps, a jump
// into the stage's cloud, "Read the full answer".
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createPeerLinks } from "../../../lib/samagotchi/web/public/peer_links.js";
import { createPeers } from "../../../lib/samagotchi/web/public/peer_data.js";
import { elementOf, noteBubbleTemplate, toolRowTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";

const T0 = Date.now() - 10 * 60_000;
const at = (min) => new Date(T0 + min * 60_000).toISOString();
const ex = {
  a: { id: "s-a", kind: "validate", title: "phase A", at: at(0), state: "answered", answer: { summary: "phase A: VERDICT CHANGES", at: at(6), serial: 3, verdict: "CHANGES" } },
  b: { id: "s-b", kind: "question", title: "naming", at: at(8), state: "waiting" },
  loose: { id: null, at: at(9), state: "answered", answer: { summary: "by the way", at: at(9), serial: 5 } },
};
const PEERS = { peers: [{ name: "claude", label: "Claude", inbox: true, outbox: true, exchanges: [ex.loose, ex.b, ex.a] }] };

const sendRow = (id, key, output = "sent to Claude: validate · phase A. Claude's answer comes …") => elementOf(toolRowTemplate({
  key, tool: "claude_send", status: "ok", title: "validate: phase A", output,
  refs: [{ kind: "peer", target: { id }, label: "Claude · validate" }],
}));
const answer = (serial, re, summary = "phase A: VERDICT CHANGES") => elementOf(noteBubbleTemplate({
  content: "Updated: claude-outbox …", context_source: "claude-outbox",
  peer: { peer: "claude", label: "Claude", re, summary, serial, verdict: "CHANGES" },
}));

// A history (a folded finished turn holding the first send), a stage, a model.
function page({ running = false } = {}) {
  const history = document.createElement("div");
  const stage = document.createElement("div");
  stage.className = "turn-stage";
  document.body.replaceChildren(history, stage);
  const turn = document.createElement("details");
  turn.className = "turn-work";
  turn.append(document.createElement("summary"), sendRow("s-a", "r1"));
  history.append(turn, answer(3, "s-a"), sendRow("s-a", "r2"), answer(5, null, "by the way"));
  const shown = [];
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => links.hasPeer(), onChange: () => links.draw(),
                              list: async () => PEERS, win: { addEventListener() {} } });
  const links = createPeerLinks({ peers, roots: () => [history, stage], running: () => running, showText: (name) => shown.push(name), behavior: () => "auto" });
  return { history, stage, peers, links, shown };
}

test("before the read, the slots wait empty; after it, both rows of s-a show its answered state", async () => {
  const { history, links } = page();
  links.draw();
  assert.equal(history.querySelector(".peer-slot").textContent, "");
  await links.drawn();
  const pills = [...history.querySelectorAll(".peer-slot")].map((slot) => slot.querySelector(".peer-state"));
  assert.equal(pills.length, 2);
  for (const pill of pills) {
    assert.equal(pill.localName, "button");
    assert.equal(pill.querySelector(".peer-long").textContent, "changes · answered after 6m");
    // The output is the pill's hover, not a line.
    assert.match(pill.title, /^sent to Claude: validate · phase A/);
  }
  assert.ok(history.querySelector(".activity-output") === null);
});

test("a send whose id the log never saw reads 'not sent' once its turn ended, nothing while it runs in the stage", async () => {
  const { history, stage, links } = page({ running: true });
  history.append(sendRow("s-gone", "r3"));
  stage.append(sendRow("s-new", "r4"));
  await links.drawn();
  const slotOf = (id) => [...document.querySelectorAll(".peer-slot")].find((s) => s.dataset.peerRef === id);
  assert.equal(slotOf("s-gone").textContent, "not sent");
  assert.equal(slotOf("s-new").textContent, "");
});

test("the answers: ↑ names the send it answers, none on an unclaimed one; 'Read the full answer' on the newest only", async () => {
  const { history, links, shown } = page();
  await links.drawn();
  const [first, loose] = history.querySelectorAll(".peer-answer");
  assert.equal(first.querySelector(".peer-up").textContent, "validate · phase A ↑");
  assert.ok(loose.querySelector(".peer-up") === null);
  assert.ok(first.querySelector(".peer-full") === null);
  const full = loose.querySelector(".peer-full");
  assert.equal(full.textContent, "Read the full answer");
  full.click();
  assert.deepEqual(shown, ["claude-outbox"]);
});

test("an inline newest answer gets no 'Read the full answer'; its text is swapped for its markdown once, the source kept", async () => {
  const history = document.createElement("div");
  document.body.replaceChildren(history);
  const content = "Updated: claude-outbox …\n> by the way\n[PEER MESSAGE from Claude]\n**bold**\n[END PEER MESSAGE]\nIts message is above.";
  const inline = elementOf(noteBubbleTemplate({ content, context_source: "claude-outbox",
    peer: { peer: "claude", label: "Claude", summary: "by the way", serial: 5, inline: true } }));
  history.append(answer(3, "s-a"), inline);
  const asked = [];
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, onChange: () => {}, list: async () => PEERS, win: { addEventListener() {} } });
  const links = createPeerLinks({ peers, roots: () => [history], renderMarkdown: async (text) => { asked.push(text); return "<p><strong>bold</strong></p>"; } });
  await links.drawn();
  links.draw();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(history.querySelector(".peer-full") === null);
  const text = inline.querySelector(".peer-text");
  assert.deepEqual(asked, ["**bold**"]);
  assert.ok(text.classList.contains("markdown"));
  assert.equal(text.querySelector("strong").textContent, "bold");
  assert.equal(text.dataset.peerMd, "**bold**");
});

test("an inline answer's text stays plain when markdown is off (no renderMarkdown, or a null read)", async () => {
  const history = document.createElement("div");
  document.body.replaceChildren(history);
  const inline = elementOf(noteBubbleTemplate({ content: "x\n[PEER MESSAGE from Claude]\n**b**\n[END PEER MESSAGE]\ny", context_source: "claude-outbox",
    peer: { peer: "claude", label: "Claude", summary: "s", serial: 5, inline: true } }));
  history.append(inline);
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, onChange: () => {}, list: async () => PEERS, win: { addEventListener() {} } });
  createPeerLinks({ peers, roots: () => [history], renderMarkdown: async () => null }).draw();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(inline.querySelector(".peer-text").textContent, "**b**");
  assert.ok(!inline.querySelector(".peer-text").classList.contains("markdown"));
});

test("↓ on a send goes to its answer: revealed, scrolled to, focused; ↑ goes back to the last send of its id before it", async () => {
  const { history, links } = page();
  await links.drawn();
  const note = history.querySelector(".peer-answer");
  note.classList.add("folded");
  let scrolled = null;
  note.scrollIntoView = () => { scrolled = note; };
  history.querySelectorAll(".peer-slot button")[1].click();
  assert.equal(scrolled, note);
  assert.ok(!note.classList.contains("folded"));
  assert.equal(document.activeElement, note);
  assert.equal(note.getAttribute("tabindex"), "-1");
  // ↑: the row in the folded turn (before the answer), not the resend after it.
  const turn = history.querySelector(".turn-work");
  const row = turn.querySelector(".activity-row");
  row.scrollIntoView = () => {};
  assert.equal(turn.open, false);
  note.querySelector(".peer-up").click();
  assert.equal(turn.open, true);
  assert.equal(document.activeElement, row);
  assert.ok(row.classList.contains("ref-flash"));
});

test("↑ into the stage's cloud: the row's ref:reveal asks the stage to open it", async () => {
  const { history, stage, links } = page({ running: true });
  // The only row of s-b is the running turn's, in the stage.
  stage.append(sendRow("s-b", "r5"));
  history.append(answer(9, "s-b"));
  PEERS.peers[0].exchanges.unshift({ ...ex.b, state: "answered", answer: { summary: "naming: VERDICT OK", at: at(9), serial: 9, verdict: "OK" } });
  try {
    await links.drawn();
    let revealed = 0;
    stage.addEventListener("ref:reveal", () => { revealed += 1; });
    const row = stage.querySelector(".activity-row");
    row.scrollIntoView = () => {};
    history.querySelector(".peer-answer:last-of-type .peer-up").click();
    assert.equal(revealed, 1);
    assert.equal(document.activeElement, row);
  } finally {
    PEERS.peers[0].exchanges.shift();
  }
});

test("a jump never changes the route: buttons, no href", async () => {
  const { history, links } = page();
  await links.drawn();
  const before = window.location.hash;
  assert.equal(history.querySelectorAll("a[href]").length, 0);
  history.querySelectorAll(".peer-slot button")[0].click();
  assert.equal(window.location.hash, before);
});

test("a failed send's Error: output draws as today, beside a 'not sent' pill", async () => {
  const { history, links } = page();
  const failed = elementOf(toolRowTemplate({ key: "r9", tool: "claude_send", status: "error", title: "validate: x", output: "Error: no paired Claude",
                                             refs: [{ kind: "peer", target: { id: "s-x" } }] }));
  history.append(failed);
  await links.drawn();
  assert.equal(failed.querySelector(".activity-output").textContent, "Error: no paired Claude");
  assert.equal(failed.querySelector(".peer-slot").textContent, "not sent");
});

// A peer whose list is the server's whole cap (20, newest first): s-n0 the newest.
function fullList(count = 20) {
  return Array.from({ length: count }, (_, i) => ({ id: `s-n${i}`, kind: "context", title: `t${i}`, at: at(30 - i), state: "none_expected" }));
}

function cappedPage(list) {
  const history = document.createElement("div");
  document.body.replaceChildren(history);
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, onChange: () => links.draw(),
                              list: async () => list, win: { addEventListener() {} } });
  const links = createPeerLinks({ peers, roots: () => [history], behavior: () => "auto" });
  const slot = (id) => [...history.querySelectorAll(".peer-slot")].find((s) => s.dataset.peerRef === id);
  return { history, links, slot };
}

test("a full list (the server's cap): an older send it leaves out has no pill; one drawn after a listed send reads 'not sent'", async () => {
  const { history, links, slot } = cappedPage({ peers: [{ name: "claude", exchanges: fullList() }] });
  history.append(sendRow("s-old", "o1"), sendRow("s-n19", "n19"), sendRow("s-gone", "g1"), sendRow("s-n0", "n0"));
  await links.drawn();
  assert.equal(slot("s-old").textContent, "");
  assert.ok(slot("s-old").querySelector(".peer-state") === null);
  assert.equal(slot("s-gone").textContent, "not sent");
  // Under the cap the list is whole: a missing id didn't go out.
  const short = cappedPage({ peers: [{ name: "claude", exchanges: fullList(19) }] });
  short.history.append(sendRow("s-old", "o1"));
  await short.links.drawn();
  assert.equal(short.slot("s-old").textContent, "not sent");
});

test("a peer the read doesn't name (detached, an older chi web's 404) leaves its sends unknown, unless the row itself failed", async () => {
  for (const list of [{ peers: [] }, { peers: [{ name: "codex", exchanges: [] }] }]) {
    const { history, links, slot } = cappedPage(list);
    history.append(sendRow("s-a", "r1"));
    const failed = elementOf(toolRowTemplate({ key: "r2", tool: "claude_send", status: "error", title: "validate: x", output: "Error: that Claude session is gone",
                                               refs: [{ kind: "peer", target: { id: "s-x" } }] }));
    history.append(failed);
    await links.drawn();
    assert.equal(slot("s-a").textContent, "");
    assert.equal(slot("s-x").textContent, "not sent");
  }
});

test("a second answer to one send links back to it by its re", async () => {
  const { history, links } = page();
  const second = { id: null, at: at(7), state: "answered", answer: { summary: "phase A: one more", at: at(7), serial: 6 } };
  PEERS.peers[0].exchanges.unshift(second);
  try {
    history.append(answer(6, "s-a", "phase A: one more"));
    await links.drawn();
    assert.equal([...history.querySelectorAll(".peer-answer")].at(-1).querySelector(".peer-up").textContent, "validate · phase A ↑");
  } finally {
    PEERS.peers[0].exchanges.shift();
  }
});

test("hasSend / showSend (the peer chip's exchange list): the last row of an id, shown and focused; false for none drawn", async () => {
  const { history, links } = page();
  await links.drawn();
  assert.equal(links.hasSend("s-a"), true);
  assert.equal(links.hasSend("s-x"), false);
  const rows = [...history.querySelectorAll(".activity-row")];
  rows.forEach((row) => { row.scrollIntoView = () => {}; });
  assert.equal(links.showSend("s-a"), true);
  assert.equal(document.activeElement, rows.at(-1));
  assert.equal(links.showSend("s-x"), false);
});
