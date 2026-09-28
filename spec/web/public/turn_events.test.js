import test from "node:test";
import assert from "node:assert/strict";
import { turnOutput, workerGoneText } from "../../../lib/samagotchi/web/public/turn_events.js";

test("turnOutput reads turn_summary.output (result is a string on the wire)", () => {
  const data = { type: "turn_completed", result: "\nPONG", turn_summary: { output: "\nPONG" } };
  assert.equal(turnOutput(data), "PONG");
});

test("turnOutput falls back to a string result, then content/output", () => {
  assert.equal(turnOutput({ result: " ANSWER " }), "ANSWER");
  assert.equal(turnOutput({ result: { output: "OBJ" } }), "OBJ");
  assert.equal(turnOutput({ content: "C" }), "C");
  assert.equal(turnOutput({ output: "O" }), "O");
});

test("turnOutput is empty for a turn with no text", () => {
  assert.equal(turnOutput({}), "");
  assert.equal(turnOutput(null), "");
  assert.equal(turnOutput({ turn_summary: { output: "  " } }), "");
});

import { clientLabel, isOwn, newClientId, promptOps } from "../../../lib/samagotchi/web/public/turn_events.js";

const ME = "web:me";
const none = { myId: ME, known: () => false };

test("newClientId is web:<random>, different per call", () => {
  const a = newClientId();
  assert.match(a, /^web:[a-z0-9]{8,}$/);
  assert.notEqual(a, newClientId());
});

test("clientLabel names the sender's kind; own/unknown have none", () => {
  assert.equal(clientLabel("tui:123"), "tui");
  assert.equal(clientLabel("web:abc"), "web");
  assert.equal(clientLabel("system:reminder"), "reminder");
  assert.equal(clientLabel("delegate:3f2a1c9e"), "delegate");
  assert.equal(clientLabel("other:1"), "user");
  assert.equal(clientLabel(null), null);
  assert.equal(isOwn(ME, ME), true);
  assert.equal(isOwn(null, ME), false);
});

test("another client's turn_enqueued adds a queued bubble, once", () => {
  const ev = { type: "turn_enqueued", enqueued_id: "e1", client_id: "tui:9", prompt: "hi" };
  assert.deepEqual(promptOps(ev, none), [
    { op: "add", enqueuedId: "e1", prompt: "hi", state: "queued", label: "tui" },
  ]);
  assert.deepEqual(promptOps(ev, { myId: ME, known: (id) => id === "e1" }), []);
});

test("own turn_enqueued tags the local echo instead of adding one", () => {
  const ev = { type: "turn_enqueued", enqueued_id: "e2", client_id: ME, prompt: "mine" };
  assert.deepEqual(promptOps(ev, none), [{ op: "tag", enqueuedId: "e2", prompt: "mine" }]);
});

test("turn_started starts a known bubble, or adds the prompt it never saw", () => {
  const started = { type: "turn_started", prompt: "p", origin: { client_id: "tui:1", enqueued_id: "e3" } };
  assert.deepEqual(promptOps(started, { myId: ME, known: (id) => id === "e3" }), [
    { op: "start", enqueuedId: "e3", prompt: "p" },
  ]);
  assert.deepEqual(promptOps(started, none), [
    { op: "add", enqueuedId: "e3", prompt: "p", state: "started", label: "tui" },
  ]);
});

test("a reminder turn arrives only as turn_started", () => {
  const ev = { type: "turn_started", prompt: "stand up", origin: { client_id: "system:reminder" } };
  assert.deepEqual(promptOps(ev, none), [
    { op: "add", enqueuedId: null, prompt: "stand up", state: "started", label: "reminder" },
  ]);
});

test("own turn_started without a tag starts the echo by its text", () => {
  const ev = { type: "turn_started", prompt: "mine", origin: { client_id: ME, enqueued_id: "e4" } };
  assert.deepEqual(promptOps(ev, none), [{ op: "start", enqueuedId: "e4", prompt: "mine" }]);
});

test("own turn_started carries its images, for an echo a resync wiped", () => {
  const images = [{ file: "a.png", name: "a.png" }];
  const ev = { type: "turn_started", prompt: "mine", images, origin: { client_id: ME, enqueued_id: "e5" } };
  assert.deepEqual(promptOps(ev, none), [{ op: "start", enqueuedId: "e5", prompt: "mine", images }]);
});

test("a continue turn and a prompt-less start render no bubble", () => {
  assert.deepEqual(promptOps({ type: "turn_started", prompt: "x", continue: true }, none), []);
  assert.deepEqual(promptOps({ type: "turn_started", prompt: "" }, none), []);
});

test("input_merged steers every known origin; pending_input_merged adds the rest", () => {
  const known = (id) => id === "e5";
  const merged = { type: "input_merged", count: 2, origins: [{ client_id: "tui:1", enqueued_id: "e5" }, { enqueued_id: "e6" }] };
  assert.deepEqual(promptOps(merged, { myId: ME, known }), [
    { op: "steer", enqueuedId: "e5" },
    { op: "steer", enqueuedId: "e6", unmatched: true },
  ]);
  // The merged text: shown only when some origin had no bubble.
  const text = { type: "pending_input_merged", content: "a\nb" };
  assert.deepEqual(promptOps(text, { myId: ME, known, unmatchedMerge: true }), [
    { op: "add", enqueuedId: null, prompt: "a\nb", state: "steered", label: null },
  ]);
  assert.deepEqual(promptOps(text, { myId: ME, known, unmatchedMerge: false }), []);
});

import { snapshotEvents } from "../../../lib/samagotchi/web/public/turn_events.js";

test("snapshotEvents replays the turn in progress as live events, then the queued prompts", () => {
  const turn = {
    prompt: "do it",
    origin: { client_id: "tui:1", enqueued_id: "e1" },
    parts: [
      { kind: "thinking", iteration: 1, text: "hmm" },
      { kind: "text", iteration: 1, text: "Let me look." },
      { kind: "tool", iteration: 1, call_index: 0, tool: "execute", params: "ls", status: "ok", output: "a b", output_truncated: false },
      { kind: "input", iteration: 2, text: "also this", origins: [{ client_id: "web:x", enqueued_id: "e2" }] },
      { kind: "reminder", reminders: ["r"] },
      { kind: "hook_notice", hook: "known_names.rb (bundle known-names)", text: "rejected execute", level: "info" },
      { kind: "tool", iteration: 2, call_index: 0, tool: "read", params: "f", status: "running" },
    ],
  };
  const queued = [{ enqueued_id: "e3", client_id: "web:y", prompt: "later" }];
  assert.deepEqual(snapshotEvents({ current_turn: turn, queued, started_at: "T0" }), [
    { type: "turn_started", prompt: "do it", origin: turn.origin, continue: false, started_at: "T0" },
    { type: "generation_chunk", text: "", thinking: "hmm", iteration: 1 },
    { type: "generation_chunk", text: "Let me look.", thinking: "", iteration: 1 },
    { type: "generation_completed" },
    { type: "tool_call_started", iteration: 1, call_index: 0, tool: "execute", params: "ls" },
    { type: "tool_call_completed", iteration: 1, call_index: 0, tool: "execute", output: "a b", output_truncated: false, activity: { status: "ok", params: "ls" } },
    { type: "merged_input", content: "also this", origins: [{ client_id: "web:x", enqueued_id: "e2" }] },
    { type: "reminder_injected", reminders: ["r"] },
    { type: "hook_notice", hook: "known_names.rb (bundle known-names)", text: "rejected execute", level: "info" },
    { type: "tool_call_started", iteration: 2, call_index: 0, tool: "read", params: "f" },
    { type: "turn_enqueued", enqueued_id: "e3", client_id: "web:y", prompt: "later" },
  ]);
});

test("snapshotEvents splits text by iteration and leaves the last one streaming", () => {
  const turn = { prompt: "p", parts: [
    { kind: "text", iteration: 1, text: "one" },
    { kind: "text", iteration: 2, text: "two" },
  ] };
  assert.deepEqual(snapshotEvents({ current_turn: turn }).map((e) => e.type), [
    "turn_started", "generation_chunk", "generation_completed", "generation_chunk",
  ]);
});

test("snapshotEvents with no turn in progress is just the queue", () => {
  assert.deepEqual(snapshotEvents({ current_turn: null, queued: [] }), []);
  assert.deepEqual(snapshotEvents({}), []);
});

import { restoreAction } from "../../../lib/samagotchi/web/public/turn_events.js";

test("restoreAction refills an empty composer with this tab's own failed prompt", () => {
  const event = { type: "prompt_restored", prompt: "boom", origin: { client_id: ME, enqueued_id: "e1" } };
  const sentIds = new Set(["e1"]);

  assert.deepEqual(restoreAction(event, { myId: ME, sentIds, composerEmpty: true }), { refill: "boom", own: true, label: null });
  // Something typed there already stays.
  assert.deepEqual(restoreAction(event, { myId: ME, sentIds, composerEmpty: false }), { refill: null, own: true, label: null });
});

test("restoreAction never refills a prompt this page didn't send (a replay after reload, another client)", () => {
  const replayed = { type: "prompt_restored", prompt: "old", origin: { client_id: ME, enqueued_id: "e-old" } };
  const theirs = { type: "prompt_restored", prompt: "theirs", origin: { client_id: "tui:42", enqueued_id: "e2" } };
  const initial = { type: "prompt_restored", prompt: "first", origin: null };
  const opts = { myId: ME, sentIds: new Set(["e1"]), composerEmpty: true };

  assert.deepEqual(restoreAction(replayed, opts), { refill: null, own: true, label: null });
  assert.deepEqual(restoreAction(theirs, opts), { refill: null, own: false, label: "tui" });
  assert.deepEqual(restoreAction(initial, opts), { refill: null, own: false, label: null });
});

import { commandView, continueLine, isCommandLine, webLocalReply } from "../../../lib/samagotchi/web/public/turn_events.js";

test("isCommandLine: a composer line starting with / or ! goes to the command route", () => {
  assert.equal(isCommandLine("/model x"), true);
  assert.equal(isCommandLine("  !ls"), true);
  assert.equal(isCommandLine("hello /model"), false);
  assert.equal(isCommandLine(""), false);
});

test("webLocalReply: /archive and /exit are answered by the page, other commands go to the worker", () => {
  assert.match(webLocalReply("/archive"), /^\/archive: use the archive button/);
  assert.match(webLocalReply("  /EXIT now "), /^\/exit: /);
  assert.equal(webLocalReply("/model x"), null);
  assert.equal(webLocalReply("/archived"), null);
  assert.equal(webLocalReply("!exit"), null);
});

test("continueLine: the card's answers as /continue commands", () => {
  assert.equal(continueLine("yes"), "/continue yes");
  assert.equal(continueLine("no"), "/continue no");
  assert.equal(continueLine("no", "  too slow "), "/continue no, too slow");
  assert.equal(continueLine("no", "   "), "/continue no");
});

test("commandView: who ran what, what it said, and whether the conversation must be re-read", () => {
  const ran = { type: "command_ran", client_id: "tui:7", line: "!rollback", status: "ok", output: "salvaged turn discarded",
                changed: ["messages"], model_name: "m1" };

  assert.deepEqual(commandView(ran, ME), { label: "tui", line: "!rollback", text: "salvaged turn discarded", busy: false,
                                           failed: false, resync: true, modelName: "m1", anytime: false, commandId: null });
  assert.deepEqual(commandView({ ...ran, client_id: ME, status: "busy", output: "busy: wait for the turn to end", changed: [] }, ME),
                   { label: null, line: "!rollback", text: "busy: wait for the turn to end", busy: true, failed: false,
                     resync: false, modelName: "m1", anytime: false, commandId: null });
  assert.equal(commandView({ ...ran, status: "error" }, ME).failed, true);
});

test("commandView: an anytime command's queued and ran events name the bubble they share", () => {
  const queued = { type: "command_queued", command_id: "c9", client_id: ME, line: "/btw why?", anytime: true };
  assert.deepEqual(commandView(queued, ME), { label: null, line: "/btw why?", text: "", busy: false, failed: false,
                                              resync: false, modelName: null, anytime: true, commandId: "c9" });
  const ran = commandView({ ...queued, type: "command_ran", status: "ok", output: "", changed: [] }, ME);
  assert.equal(ran.anytime, true);
  assert.equal(ran.commandId, "c9");
});

test("snapshotEvents replays a reminder turn's reminders (its prompt is empty)", () => {
  const turn = { prompt: null, continue: true, origin: { client_id: "system:reminder" },
                 parts: [{ kind: "reminder", reminders: [{ name: "stretch" }] }, { kind: "text", iteration: 1, text: "Time to stretch" }] };

  const events = snapshotEvents({ current_turn: turn });

  assert.deepEqual(events.slice(0, 2).map((e) => e.type), ["turn_started", "reminder_injected"]);
  assert.deepEqual(events[1].reminders, [{ name: "stretch" }]);
});

import { reminderText } from "../../../lib/samagotchi/web/public/turn_events.js";

test("reminderText names the reminders a turn got", () => {
  assert.equal(reminderText({ reminders: [{ name: "stretch" }, { name: "water" }] }), "reminder: stretch, water");
  assert.equal(reminderText({}), "reminder");
});

test("workerGoneText ends a running turn whose worker went away, and only a running one", () => {
  assert.equal(workerGoneText({ turnRunning: true, stopped: true }), "\u2715 canceled (session stopped)");
  assert.equal(workerGoneText({ turnRunning: true }), "\u2715 canceled (worker exited)");
  assert.equal(workerGoneText({ turnRunning: false, stopped: true }), null);
});

import { hookNoticeLabel } from "../../../lib/samagotchi/web/public/turn_events.js";

test("hookNoticeLabel names a bundle hook by its bundle, any other hook as hook", () => {
  assert.equal(hookNoticeLabel("known_names.rb (bundle known-names)"), "known-names");
  assert.equal(hookNoticeLabel("audit.rb (config)"), "hook");
  assert.equal(hookNoticeLabel("turn hook"), "hook");
  assert.equal(hookNoticeLabel(undefined), "hook");
});

test("snapshotEvents: a running turn's steer part replays as a steer-only merge", () => {
  const events = snapshotEvents({ current_turn: { prompt: "p", origin: {}, parts: [
    { kind: "text", iteration: 1, text: "hm" },
    { kind: "steer", iteration: 2, source: "check-in", text: "status?" },
  ] } });
  assert.deepEqual(events.slice(-2), [
    { type: "generation_completed" },
    { type: "pending_input_merged", count: 0, content: null, steers: [{ source: "check-in", text: "status?" }] },
  ]);
});

test("promptOps: a steer-only merge adds no prompt bubble, even after an unmatched input_merged", () => {
  const event = { type: "pending_input_merged", count: 0, content: null, steers: [{ source: "check-in", text: "x" }] };
  assert.deepEqual(promptOps(event, { myId: "web:a", known: () => false, unmatchedMerge: true }), []);
});

import { emptyRetryLine } from "../../../lib/samagotchi/web/public/turn_events.js";

test("emptyRetryLine says the loop asks again, with the attempt", () => {
  assert.equal(emptyRetryLine({ attempt: 1, of: 1 }), "↻ empty answer, asking again (1/1)");
});
