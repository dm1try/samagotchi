import test from "node:test";
import assert from "node:assert/strict";
import {
  authorSlot, authorColor, authorLabel, toolLine, toolsSummary, refusalText, endedText, cursorSeq, streamURL, reloads,
  liveFrom, applyLive, liveText, AUTHOR_SLOTS, pickSubject, subjectBody, subjectsKey, narrowView,
} from "../../../lib/samagotchi/web/public/participant_model.js";

test("participant: an author's colour slot is stable per id and in range; the owner has their own colour", () => {
  assert.equal(authorSlot("p:p_1"), authorSlot("p:p_1"));
  for (const id of ["p:p_1", "p:p_2", "p:p_abcdef12", ""]) {
    const slot = authorSlot(id);
    assert.ok(slot >= 1 && slot <= AUTHOR_SLOTS, `${id}: ${slot}`);
  }
  assert.equal(authorColor(undefined), "var(--author-owner)");
  assert.match(authorColor("p:p_1"), /^var\(--author-[1-6]\)$/);
});

test("participant: who wrote it: you, a participant's name, automatic, or the owner", () => {
  assert.equal(authorLabel({ mine: true, author: "p:p_1", author_name: "Alex" }), "You");
  assert.equal(authorLabel({ author: "p:p_2", author_name: "Sam" }), "Sam");
  assert.equal(authorLabel({ author: "p:p_2" }), "A participant");
  assert.equal(authorLabel({ automatic: true }), "Automatic");
  assert.equal(authorLabel({}), "Owner");
});

test("participant: a tool row is its name and project path; several fold into a summary", () => {
  assert.equal(toolLine({ tool: "read", path: "docs/plan.md" }), "read docs/plan.md");
  assert.equal(toolLine({ tool: "execute" }), "execute");
  assert.equal(toolsSummary([{ tool: "read", path: "a.md" }, { tool: "execute" }, { tool: "memory_read" }]), "read a.md + 2 more");
  assert.equal(toolsSummary([]), "");
});

test("participant: a refusal in words: not_permitted always ours, else the server's detail, else by code", () => {
  assert.match(refusalText(403, { error: "not_permitted", detail: "a participant can't do that" }), /can't start with “!” or “\/”/);
  assert.equal(refusalText(429, { error: "too_many_turns", detail: "server words" }), "server words");
  assert.match(refusalText(429, { error: "cap_reached" }), /spending cap .* reached/);
  assert.match(refusalText(429, { error: "too_many_turns" }), /too many comments waiting/);
  assert.equal(refusalText(500, null), "Not sent (HTTP 500).");
});

test("participant: an ended link says why", () => {
  assert.match(endedText({ error: "token_revoked" }), /revoked/);
  assert.match(endedText({ error: "token_expired" }), /expired/);
  assert.match(endedText(null), /expired or was revoked/);
});

test("participant: the stream goes on from the review's cursor, or joins with a snapshot; the owner's asks for the filter", () => {
  assert.equal(cursorSeq("12-ep"), 12);
  assert.equal(cursorSeq(null), null);
  assert.equal(streamURL("s1", "12-ep"), "/api/sessions/s1/stream?from_seq=12");
  assert.equal(streamURL("s1", null), "/api/sessions/s1/stream?snapshot=1");
  assert.equal(streamURL("s1", "3-ep", { owner: true }), "/api/sessions/s1/stream?from_seq=3&as=participant");
});

test("participant: turn boundaries, the queue and the owner's questions re-read; the reply's events draw live", () => {
  for (const type of ["turn_started", "turn_completed", "turn_enqueued", "question_requested", "snapshot", "reset"]) assert.ok(reloads(type), type);
  for (const type of ["generation_chunk", "tool_call_started"]) assert.ok(!reloads(type), type);
});

test("participant: the live turn: text by step, a restarted step voided, tool rows started and finished", () => {
  let live = liveFrom({ text: "So far. ", tools: [{ tool: "read", path: "a.md", status: "ok" }] });
  live = applyLive(live, { type: "generation_chunk", text: "Step one", iteration: 1 });
  live = applyLive(live, { type: "generation_retrying", restarted: true, iteration: 1 });
  live = applyLive(live, { type: "generation_chunk", text: "Again", iteration: 1 });
  live = applyLive(live, { type: "tool_call_started", tool: "execute", iteration: 1, call_index: 0 });
  live = applyLive(live, { type: "tool_call_completed", status: "error", iteration: 1, call_index: 0 });
  assert.equal(liveText(live), "So far. Again");
  assert.deepEqual(live.tools.map((row) => [row.tool, row.status]), [["read", "ok"], ["execute", "error"]]);
  assert.equal(applyLive(live, { type: "something_else" }), live);
});

test("participant: a run of tool-only steps folds into the next reply's rows, or stands alone before a prompt", async () => {
  const { withToolSteps } = await import("../../../lib/samagotchi/web/public/participant_model.js");
  const r = (tool) => ({ tool });
  const out = withToolSteps([
    { role: "user", content: "go" },
    { role: "assistant", content: "", tools: [r("execute")] },
    { role: "assistant", content: " ", tools: [r("read")] },
    { role: "assistant", content: "Done.", tools: [r("memory_read")] },
    { role: "assistant", content: "", tools: [r("ask_user_question")] },
    { role: "user", content: "next" },
  ]);
  assert.deepEqual(out.map((m) => [m.role, m.content, (m.tools || []).map((t) => t.tool)]), [
    ["user", "go", []], ["assistant", "Done.", ["execute", "read", "memory_read"]], ["assistant", "", ["ask_user_question"]],
    ["user", "next", []],
  ]);
});

test("participant: the Plan view picks its subject, says why one can't show, and redraws only on a change", () => {
  const subjects = [{ path: "docs/plan.md", text: "# P", html: "<h1>P</h1>" }, { path: "notes.txt", text: "n", truncated: true },
    { path: "gone.md", missing: true }];
  assert.equal(pickSubject(subjects, "notes.txt").path, "notes.txt");
  assert.equal(pickSubject(subjects, "nope").path, "docs/plan.md");
  assert.equal(pickSubject([], "x"), null);
  assert.deepEqual(subjectBody(subjects[0]), { kind: "html", html: "<h1>P</h1>", note: null });
  assert.deepEqual(subjectBody(subjects[1]), { kind: "text", text: "n", note: "Only the start of this file is shown: it is long." });
  assert.match(subjectBody(subjects[2]).text, /gone\.md can't be shown/);
  assert.equal(subjectsKey(subjects), subjectsKey(subjects.map((s) => ({ ...s, html: "changed html only" }))));
  assert.notEqual(subjectsKey(subjects), subjectsKey([{ ...subjects[0], text: "# Q" }]));
  assert.equal(narrowView("plan", subjects), "plan");
  assert.equal(narrowView("plan", []), "thread");
  assert.equal(narrowView(undefined, subjects), "thread");
});
