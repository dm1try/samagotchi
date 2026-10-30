// Where Verify is offered (verify_target.js): only in an ended turn's final
// answer, Engine#verified_anchor's rule, over the owner's real history
// markup (turnHistoryNodes) and the participant page's thread shape.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { OWNER_FINAL, PARTICIPANT_FINAL, verifyTurnOf } from "../../../lib/samagotchi/web/public/verify_target.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

const thumbs = () => "";

function ownerHistory(items, records) {
  const holder = document.createElement("div");
  holder.append(turnHistoryNodes(items, normalizeTiming({ turn_records: records }), { thumbs }));
  return holder;
}

const ITEMS = [
  { role: "user", content: "First", turn_id: "T1" },
  { role: "assistant", content: "Old answer" },
  { role: "user", content: "Is the cache keyed?", turn_id: "T2" },
  { role: "assistant", content: "Looking.", parts: { tools: [{ tool: "read", params: 'path="keys.rb"', output: "[read]\nok" }] } },
  { role: "user", content: "session: c1", source: "delegate_report", merged: true, step: 2 },
  { role: "assistant", content: "Report says so.", parts: { tools: [{ tool: "read", params: 'path="ttl.rb"', output: "[read]\nok" }] } },
  { role: "user", content: "also the TTL", merged: true, step: 3 },
  { role: "assistant", content: "The cache is keyed by path." },
];
const RECORDS = [{ id: "T1", duration_ms: 5 }, { id: "T2", duration_ms: 5 }];

test("owner's page: Verify only in a turn's final answer bubble, anchored to its turn", () => {
  const history = ownerHistory(ITEMS, RECORDS);
  const bubble = (text) => {
    const found = [...history.querySelectorAll(".bubble.output, .gen-text, .bubble.user .user-message")]
      .find((el) => el.textContent.trim() === text);
    assert.ok(found, text);
    return found;
  };
  assert.equal(verifyTurnOf(history, bubble("The cache is keyed by path."), OWNER_FINAL), "T2");
  assert.equal(verifyTurnOf(history, bubble("Old answer"), OWNER_FINAL), "T1");
  // Not a step's text, a delegate report's reply, a merged line or a prompt.
  assert.equal(verifyTurnOf(history, bubble("Looking."), OWNER_FINAL), null);
  assert.ok(history.querySelector(".bubble.output.report-reply"), "the report's reply shows as a bubble");
  assert.equal(verifyTurnOf(history, history.querySelector(".report-reply"), OWNER_FINAL), null);
  assert.equal(verifyTurnOf(history, bubble("Report says so."), OWNER_FINAL), null);
  assert.equal(verifyTurnOf(history, bubble("also the TTL"), OWNER_FINAL), null);
  assert.equal(verifyTurnOf(history, bubble("Is the cache keyed?"), OWNER_FINAL), null);
  // A node inside the answer counts as the answer.
  const text = bubble("Old answer").firstChild;
  assert.equal(verifyTurnOf(history, text, OWNER_FINAL), "T1");
});

test("owner's page: no Verify in the running turn (the newest, or the one with the running id), the ended ones keep it", () => {
  const history = ownerHistory(ITEMS, RECORDS);
  const answers = [...history.querySelectorAll(".bubble.output:not(.report-reply)")];
  assert.equal(verifyTurnOf(history, answers[1], OWNER_FINAL, { running: { turnId: "T2" } }), null);
  assert.equal(verifyTurnOf(history, answers[1], OWNER_FINAL, { running: { turnId: null } }), null);
  assert.equal(verifyTurnOf(history, answers[0], OWNER_FINAL, { running: { turnId: "T2" } }), "T1");
  assert.equal(verifyTurnOf(history, answers[0], OWNER_FINAL, { running: { turnId: "T1" } }), null);
});

test("owner's page: a context wake turn's answer isn't the turn before's (its note bubble ends that turn)", () => {
  const history = ownerHistory([
    { role: "user", content: "First", turn_id: "T1" },
    { role: "assistant", content: "Old answer" },
    { role: "note", content: "build done", label: "ci", turn_start: true, turn_id: "W1" },
    { role: "assistant", content: "Noted the build." },
  ], [{ id: "T1", duration_ms: 5 }, { id: "W1", duration_ms: 5 }]);
  const [old, wake] = history.querySelectorAll(".bubble.output");
  assert.equal(wake.textContent, "Noted the build.");
  assert.equal(verifyTurnOf(history, old, OWNER_FINAL), "T1");
  assert.equal(verifyTurnOf(history, wake, OWNER_FINAL), null);
});

test("owner's page: before any turn, or outside the history, no Verify", () => {
  const history = ownerHistory([{ role: "assistant", content: "Hello." }], []);
  assert.equal(verifyTurnOf(history, history.querySelector(".bubble.output"), OWNER_FINAL), null);
  assert.equal(verifyTurnOf(history, document.createElement("div"), OWNER_FINAL), null);
  assert.equal(verifyTurnOf(null, history, OWNER_FINAL), null);
});

// The participant thread's shape (participant.js messageNode): .p-msg.user
// (data-turn-id on a turn's prompt), .p-msg.reply holding its tools and a
// .p-bubble.
function thread(rows) {
  const root = document.createElement("div");
  for (const [kind, text, turnId] of rows) {
    const msg = document.createElement("div");
    msg.className = `p-msg ${kind}`;
    if (turnId) msg.dataset.turnId = turnId;
    if (text) {
      const bubble = document.createElement("div");
      bubble.className = "p-bubble";
      bubble.textContent = text;
      msg.append(bubble);
    }
    root.append(msg);
  }
  return root;
}

test("participant page: Verify only in a turn's last reply bubble", () => {
  const root = thread([
    ["user", "First", "T1"], ["reply", "Old answer"],
    ["user", "Is it keyed?", "T2"], ["reply", "Looking."], ["user", "also the TTL"], ["reply", ""], ["reply", "Keyed by path."],
  ]);
  const bubble = (text) => {
    const found = [...root.querySelectorAll(".p-bubble")].find((el) => el.textContent === text);
    assert.ok(found, text);
    return found;
  };
  assert.equal(verifyTurnOf(root, bubble("Keyed by path."), PARTICIPANT_FINAL), "T2");
  assert.equal(verifyTurnOf(root, bubble("Old answer"), PARTICIPANT_FINAL), "T1");
  assert.equal(verifyTurnOf(root, bubble("Looking."), PARTICIPANT_FINAL), null);
  assert.equal(verifyTurnOf(root, bubble("also the TTL"), PARTICIPANT_FINAL), null);
  assert.equal(verifyTurnOf(root, bubble("Is it keyed?"), PARTICIPANT_FINAL), null);
  assert.equal(verifyTurnOf(root, bubble("Keyed by path."), PARTICIPANT_FINAL, { running: { turnId: "T2" } }), null);
});
