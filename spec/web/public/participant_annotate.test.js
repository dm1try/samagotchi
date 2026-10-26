import test from "node:test";
import assert from "node:assert/strict";
import {
  messageAuthorData, participantLabel, participantQuote, participantSource,
} from "../../../lib/samagotchi/web/public/participant_annotate.js";

// A stand-in element: `closest` answers from a { selector: element } map;
// classes and dataset as given.
function fakeEl(chain = {}, { classes = [], dataset = {} } = {}) {
  return { nodeType: 1, dataset, classList: { contains: (c) => classes.includes(c) }, closest: (sel) => chain[sel] || null };
}

// A thread bubble inside its .p-msg (+classes+ the message's).
function bubbleIn(classes, dataset = {}) {
  const msg = fakeEl({}, { classes: ["p-msg", ...classes], dataset });
  const bubble = fakeEl({ ".p-msg": msg });
  return { bubble, node: fakeEl({ ".p-bubble": bubble }) };
}

test("participantSource: the Plan names the subject shown", () => {
  const plan = fakeEl({}, { dataset: { path: "docs/plan.md" } });
  assert.deepEqual(participantSource(fakeEl({ "#planDoc": plan })), { kind: "plan", path: "docs/plan.md", root: plan });
  // From a text node's parent.
  const parent = fakeEl({ "#planDoc": plan });
  assert.equal(participantSource({ nodeType: 3, parentElement: parent }).kind, "plan");
});

test("participantSource: the Plan's truncation note isn't the subject's text", () => {
  const plan = fakeEl({}, { dataset: { path: "a.md" } });
  assert.equal(participantSource(fakeEl({ "#planDoc": plan, ".p-plan-note": fakeEl() })), null);
});

test("participantSource: a reply's bubble, a comment's bubble with whose it is", () => {
  const reply = bubbleIn(["reply"]);
  assert.deepEqual(participantSource(reply.node), { kind: "reply", root: reply.bubble });
  const comment = bubbleIn(["user"], { by: "participant", name: "Alex" });
  assert.deepEqual(participantSource(comment.node), { kind: "comment", by: "participant", name: "Alex", root: comment.bubble });
  const owner = bubbleIn(["user"]);
  assert.equal(participantSource(owner.node).by, "owner");
});

test("participantSource: refuses the streaming reply, tool rows, status lines and anything outside a bubble", () => {
  assert.equal(participantSource(bubbleIn(["reply", "live"]).node), null);
  // A tool row, a waiting line, a time gap, the header: no .p-bubble around.
  assert.equal(participantSource(fakeEl({ ".p-tools": fakeEl(), ".p-msg": fakeEl() })), null);
  assert.equal(participantSource(fakeEl({})), null);
  assert.equal(participantSource(null), null);
  assert.equal(participantSource({ nodeType: 3, parentElement: null }), null);
});

test("participantLabel: review words for each source", () => {
  assert.equal(participantLabel({ kind: "plan", path: "docs/plan.md" }), "From docs/plan.md:");
  assert.equal(participantLabel({ kind: "plan", path: "" }), "From the plan:");
  assert.equal(participantLabel({ kind: "reply" }), null);
  assert.equal(participantLabel({ kind: "comment", by: "me" }), "From my earlier comment:");
  assert.equal(participantLabel({ kind: "comment", by: "participant", name: "Alex" }), "From Alex's comment:");
  assert.equal(participantLabel({ kind: "comment", by: "participant", name: "" }), "From a participant's comment:");
  assert.equal(participantLabel({ kind: "comment", by: "owner" }), "From the owner's message:");
  assert.equal(participantLabel({ kind: "comment", by: "automatic" }), "From the automatic turn:");
});

test("participantQuote: the label over the quoted lines; a reply unlabelled; no text, no quote", () => {
  assert.equal(participantQuote("\nstep 3\n\nstep 4  \n", { kind: "plan", path: "a.md" }), "From a.md:\n> step 3\n>\n> step 4\n\n");
  assert.equal(participantQuote("PONG", { kind: "reply" }), "> PONG\n\n");
  assert.equal(participantQuote("mine", { kind: "comment", by: "me" }), "From my earlier comment:\n> mine\n\n");
  assert.equal(participantQuote("  \n ", { kind: "plan", path: "a.md" }), null);
});

test("messageAuthorData: whose a review message is", () => {
  assert.deepEqual(messageAuthorData({ mine: true, author: "p:1", author_name: "Alex" }), { by: "me" });
  assert.deepEqual(messageAuthorData({ author: "p:2", author_name: "Sam" }), { by: "participant", name: "Sam" });
  assert.deepEqual(messageAuthorData({ author: "p:2" }), { by: "participant", name: "" });
  assert.deepEqual(messageAuthorData({ automatic: true }), { by: "automatic" });
  assert.deepEqual(messageAuthorData({}), { by: "owner" });
});
