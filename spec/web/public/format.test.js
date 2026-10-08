import test from "node:test";
import assert from "node:assert/strict";
import { leadTrimmed, previewOf, relativeTime, escapeHtml, messageBodyHtml, normalize, modelLabel, userBodyHtml, noteHtml, steerRowHtml, recapLabel, canStopSession, goneSessionNotice, withLiveStatus, withoutWorker, recapPlace, promptNotesChip } from "../../../lib/samagotchi/web/public/format.js";

test("noteHtml: who sent the context note, then its text, both escaped", () => {
  assert.equal(
    noteHtml({ label: "session 3f2a1c (~/p/<x>)", content: "a <b>\nc" }),
    '<div class="note-line">note from session 3f2a1c (~/p/&lt;x&gt;)</div><div class="note-text">a &lt;b&gt;\nc</div>',
  );
  assert.equal(noteHtml({ content: "x" }), '<div class="note-line">note</div><div class="note-text">x</div>');
});

test("escapeHtml escapes HTML metacharacters", () => {
  assert.equal(escapeHtml(`<a href="x">&`), "&lt;a href=&quot;x&quot;&gt;&amp;");
});

test("messageBodyHtml only uses explicitly rendered assistant HTML", () => {
  assert.deepEqual(
    messageBodyHtml({ role: "assistant", content: "**safe**", html: "<strong>safe</strong>" }),
    { body: "<strong>safe</strong>", renderedMarkdown: true },
  );
  assert.deepEqual(
    messageBodyHtml({ role: "user", content: "<img>", html: "<strong>ignored</strong>" }),
    { body: "&lt;img&gt;", renderedMarkdown: false },
  );
  assert.deepEqual(
    messageBodyHtml({ role: "assistant", content: "<img>" }),
    { body: "&lt;img&gt;", renderedMarkdown: false },
  );
});

test("userBodyHtml leaves a message without quotes as escaped text", () => {
  assert.equal(userBodyHtml("a <b>\n\n  c"), "a &lt;b&gt;\n\n  c");
  assert.equal(userBodyHtml(undefined), "");
});

test("userBodyHtml turns runs of > lines into blockquotes", () => {
  assert.equal(
    userBodyHtml("From your thinking:\n> one <x>\n>two\n\nwhy?\n\n> three\n\nok"),
    "From your thinking:<blockquote>one &lt;x&gt;\ntwo</blockquote>why?<blockquote>three</blockquote>ok",
  );
});

test("userBodyHtml keeps an empty quote line and handles CRLF", () => {
  assert.equal(userBodyHtml("> a\r\n>\r\n> b\r\n\r\nnote"), "<blockquote>a\n\nb</blockquote>note");
});

test("messageBodyHtml renders a user message's quotes", () => {
  assert.deepEqual(
    messageBodyHtml({ role: "user", content: "> q\n\nn" }),
    { body: "<blockquote>q</blockquote>n", renderedMarkdown: false },
  );
});

test("normalize collapses whitespace", () => {
  assert.equal(normalize("  a\n\t b   "), "a b");
  assert.equal(normalize(undefined), "");
});

test("previewOf falls back to an em dash on empty input", () => {
  assert.equal(previewOf(""), "\u2014");
  assert.equal(previewOf(null), "\u2014");
  assert.equal(previewOf(undefined), "\u2014");
});

test("previewOf normalizes whitespace and trims", () => {
  assert.equal(previewOf("  hello\nworld  "), "hello world");
});

test("previewOf truncates at 40 chars with an ellipsis", () => {
  const fortyOne = "a".repeat(41);
  const result = previewOf(fortyOne);
  assert.equal(result.length, 41);
  assert.equal(result.slice(0, 40), "a".repeat(40));
  assert.equal(result.slice(-1), "\u2026");
});

test("previewOf keeps short text unchanged", () => {
  assert.equal(previewOf("short"), "short");
});
import { ownerBadge } from "../../../lib/samagotchi/web/public/format.js";

test("ownerBadge marks live sessions by who holds them", () => {
  assert.deepEqual(ownerBadge("worker", "abc"), {
    kind: "worker", text: "live", title: "A worker runs this session; a terminal joins with: chi --attach abc",
  });
  assert.deepEqual(ownerBadge("tui", "abc"), {
    kind: "tui", text: "terminal", title: "A terminal chi owns this session and doesn't share it (chi --shared would)",
  });
  assert.equal(ownerBadge(null, "abc"), null);
  assert.equal(ownerBadge(undefined, "abc"), null);
});

test("failedTurnText shows the error's one-line summary, else its message and class", async () => {
  const { failedTurnText } = await import("../../../lib/samagotchi/web/public/format.js");
  assert.equal(
    failedTurnText({ summary: "auth failed for host fw: set FW_KEY", message: "fw: set FW_KEY", error_class: "Samagotchi::LLM::AuthError" }),
    "✕ turn failed: auth failed for host fw: set FW_KEY"
  );
  assert.equal(failedTurnText({ message: "boom", error_class: "RuntimeError" }), "✕ turn failed: boom (RuntimeError)");
  assert.equal(failedTurnText({}), "✕ turn failed: error");
});

test("failedTurnText says a failed turn's work stayed (kept_steps)", async () => {
  const { failedTurnText } = await import("../../../lib/samagotchi/web/public/format.js");
  const kept = "; partial progress kept (!rollback restores the pre-turn state)";
  assert.equal(failedTurnText({ summary: "out of credits on host or", kept_steps: 3 }), `✕ turn failed: out of credits on host or${kept}`);
  assert.equal(failedTurnText({ summary: "server error", kept_steps: 0 }), `✕ turn failed: server error${kept}`);
});

test("modelLabel shows the served model with a marker when the server serves another one", () => {
  assert.deepEqual(
    modelLabel("unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M", "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M", "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"),
    {
      text: "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M ⚠",
      title: "served: ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M; asked for unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M",
      mismatch: true,
    },
  );
});

test("modelLabel keeps the model when the served name is the same or extends it, or is unknown", () => {
  const plain = { text: "openrouter:z-ai/glm-5.2:free", title: "openrouter:z-ai/glm-5.2:free", mismatch: false };
  assert.deepEqual(modelLabel("openrouter:z-ai/glm-5.2:free", "z-ai/glm-5.2", "z-ai/glm-5.2:free"), plain);
  assert.deepEqual(modelLabel("openrouter:z-ai/glm-5.2:free", null, null), plain);
  assert.deepEqual(modelLabel("m", "M-2026-01-01", "m"), { text: "m", title: "m", mismatch: false });
  assert.equal(modelLabel("a".repeat(50), null, null).text, "a".repeat(40));
});

import { deleteConfirmText } from "../../../lib/samagotchi/web/public/format.js";

test("deleteConfirmText names the session and says it can't be undone", () => {
  assert.equal(
    deleteConfirmText({ id: "3fa2b1c4-aaaa", short_id: "3fa2b1c4", first_preview: "fix the bug in the parser" }),
    "Delete session 3fa2b1c4 — \"fix the bug in the parser\"?\nIts history, notes and images are removed; this can't be undone.",
  );
});

test("deleteConfirmText cuts a long preview and says a live worker, if still running, is stopped first", () => {
  const text = deleteConfirmText({
    id: "3fa2b1c4-aaaa", short_id: "3fa2b1c4", first_preview: "x".repeat(80), owner: "worker",
  });
  assert.ok(text.startsWith(`Delete session 3fa2b1c4 — "${"x".repeat(40)}…"?`));
  assert.ok(text.endsWith("\nIf its worker is still running, it is stopped first."));
});

test("deleteConfirmText says nothing about a worker the list doesn't show", () => {
  assert.ok(!/worker/.test(deleteConfirmText({ id: "3fa2b1c4-aaaa", first_preview: "hi" })));
});

test("deleteConfirmText leaves out an empty preview", () => {
  assert.ok(deleteConfirmText({ id: "3fa2b1c4-aaaa", first_preview: "" }).startsWith("Delete session 3fa2b1c4?\n"));
});

test("relativeTime: coarse time since an ISO timestamp, \"\" for garbage", () => {
  const now = Date.parse("2026-09-24T20:00:00.000+02:00");
  const ago = (s) => new Date(now - s * 1000).toISOString();
  assert.equal(relativeTime(ago(20), now), "just now");
  assert.equal(relativeTime(ago(-30), now), "just now"); // a clock a bit ahead
  assert.equal(relativeTime(ago(5 * 60 + 10), now), "5 min ago");
  assert.equal(relativeTime(ago(2 * 3600 + 100), now), "2 h ago");
  assert.equal(relativeTime(ago(30 * 3600), now), "yesterday");
  assert.equal(relativeTime(ago(3 * 86400 + 60), now), "3 d ago");
  assert.equal(relativeTime("2026-09-12T09:15:00.123+02:00", now), "12 Sep");
  assert.equal(relativeTime("2025-09-12T09:15:00+02:00", now), "12 Sep 2025");
  assert.equal(relativeTime("2026-09-24T19:58:00.000+02:00", now), "2 min ago"); // the server's format
  assert.equal(relativeTime("garbage", now), "");
  assert.equal(relativeTime("", now), "");
  assert.equal(relativeTime(undefined, now), "");
});

test("recapLabel: how old the recap is, in turns", () => {
  assert.equal(recapLabel(0), "recap");
  assert.equal(recapLabel(undefined), "recap");
  assert.equal(recapLabel(1), "recap · before the last turn");
  assert.equal(recapLabel(3), "recap · before the last 3 turns");
  assert.equal(recapLabel(null, true), "recap · earlier");
});

test("canStopSession: only when a worker runs the session", () => {
  assert.equal(canStopSession({ owner: "worker", streaming: false }), true);
  // A send woke a worker the page hasn't re-read yet: its stream is open.
  assert.equal(canStopSession({ owner: null, streaming: true }), true);
  // Stopped or idle-exited: nothing to stop.
  assert.equal(canStopSession({ owner: null, streaming: false }), false);
  // A chi REPL owns it: the server refuses (owned_by_tui).
  assert.equal(canStopSession({ owner: "tui", streaming: true }), false);
});

test("goneSessionNotice: the short id and why the page left it", () => {
  assert.equal(goneSessionNotice("0123456789abcdef", "not_found"), "Session 01234567 was not found.");
  assert.equal(goneSessionNotice("0123456789abcdef", "deleted"), "Session 01234567 was deleted.");
  assert.equal(goneSessionNotice("<b>", "not_found"), "Session <b> was not found.");
});

test("withLiveStatus: a live status change is activity now (the card's time)", () => {
  const now = Date.parse("2026-09-25T12:00:00Z");
  const sess = { id: "a", status: "idle", updated_at: "2026-09-25T11:54:00Z", owner: "worker" };
  const next = withLiveStatus(sess, "running", now);
  assert.deepEqual(next, { id: "a", status: "running", updated_at: "2026-09-25T12:00:00.000Z", owner: "worker" });
  assert.equal(relativeTime(next.updated_at, now), "just now");
  assert.equal(sess.status, "idle"); // the input is left alone
  // A send woke a worker the list didn't know about.
  assert.equal(withLiveStatus({ id: "b", status: "stopped", owner: null }, "running", now).owner, "worker");
});

test("withoutWorker: the card of a session whose worker went away (killed, idle exit) loses live", () => {
  const sess = { id: "a", status: "running", owner: "worker" };
  assert.deepEqual(withoutWorker(sess), { id: "a", status: "idle", owner: null });
  assert.equal(sess.owner, "worker"); // the input is left alone
  assert.deepEqual(withoutWorker({ id: "b", status: "idle", owner: "worker" }), { id: "b", status: "idle", owner: null });
  // A terminal chi's session isn't the worker's to lose.
  const tui = { id: "c", status: "running", owner: "tui" };
  assert.equal(withoutWorker(tui), tui);
});

test("recapPlace: a stale recap goes before the first turn it doesn't cover", () => {
  const users = ["u1", "u2", "u3", "u4", "u5"];
  assert.equal(recapPlace(users, 3), "u3");
  assert.equal(recapPlace(users, 1), "u5");
  // Current (nothing since), or more turns than the page shows: at the end.
  assert.equal(recapPlace(users, 0), null);
  assert.equal(recapPlace(users, 9), null);
});

test("leadTrimmed drops leading whitespace only while the body is empty", () => {
  assert.equal(leadTrimmed("", "\n"), "");
  assert.equal(leadTrimmed("", "\n  Hmm, so"), "Hmm, so");
  assert.equal(leadTrimmed("Hmm", "\n\nnext"), "\n\nnext");
  assert.equal(leadTrimmed("", undefined), "");
});

import { delegatedBy } from "../../../lib/samagotchi/web/public/format.js";

test("delegatedBy names the parent by its short id, with its preview when the parent is listed", () => {
  assert.equal(delegatedBy(null), null);
  assert.equal(delegatedBy(""), null);
  assert.deepEqual(delegatedBy("3f2a1c9e-0000-4000-8000-000000000000"), {
    text: "\u21B3 3f2a1c9e", title: "delegated by session 3f2a1c9e",
  });
  assert.deepEqual(delegatedBy("3f2a1c9e-0000-4000-8000-000000000000", { last_prompt: "plan the  release" }), {
    text: "\u21B3 3f2a1c9e", title: "delegated by session 3f2a1c9e: plan the release",
  });
});

test("steerRowHtml: who nudged the model, the text collapsed and escaped; a bubble on its own", () => {
  assert.equal(steerRowHtml({ source: "check-in", text: "a <b>" }),
    '<details class="steer-row"><summary>check-in nudged the model</summary><div class="steer-text">a &lt;b&gt;</div></details>');
  assert.match(steerRowHtml({ text: "x" }, { bubble: true }), /^<details class="bubble steer-row"><summary>nudged the model</);
});

import { memChipText, memChipTitle } from "../../../lib/samagotchi/web/public/format.js";

test("memChipText / memChipTitle: the phone's memory chip counts them, the tooltip names them", () => {
  assert.equal(memChipText(["a", "b"]), "mem 2");
  assert.equal(memChipText(undefined), "mem 0");
  assert.equal(memChipTitle(["a", "b"]), "memories: a, b");
  assert.equal(memChipTitle([]), "no memories in this session");
});

import { childrenSummary, delegatesSummary } from "../../../lib/samagotchi/web/public/format.js";

test("childrenSummary: no delegates (none at all, only a fork, only archived, no parent) is null", () => {
  const parent = { id: "p1" };
  assert.equal(childrenSummary(parent, []), null);
  assert.equal(childrenSummary(parent, [{ id: "f1", parent_id: "p1", delegate: false, status: "running" }]), null);
  assert.equal(childrenSummary(parent, [{ id: "c1", parent_id: "p1", delegate: true, archived: true, status: "running" }]), null);
  assert.equal(childrenSummary(parent, [{ id: "c1", parent_id: "p2", delegate: true, status: "running" }]), null);
  assert.equal(childrenSummary(null, [{ id: "c1", parent_id: "p1", delegate: true }]), null);
});

test("childrenSummary: mixed delegates count by state; forks and other parents' children are left out", () => {
  const parent = { id: "p1" };
  const sessions = [
    parent,
    { id: "c1", parent_id: "p1", delegate: true, status: "running" },
    { id: "c2", parent_id: "p1", delegate: true, status: "running" },
    { id: "c3", parent_id: "p1", delegate: true, status: "idle", last_turn: { outcome: "completed" } },
    { id: "c4", parent_id: "p1", delegate: true, status: "idle", last_turn: { outcome: "failed" } },
    { id: "c5", parent_id: "p1", delegate: true, status: "error" },
    { id: "c6", parent_id: "p1", delegate: true, status: "stopped" },
    { id: "c7", parent_id: "p1", delegate: true, status: "idle", last_turn: { outcome: "canceled" } },
    { id: "f1", parent_id: "p1", delegate: false, status: "running" },
    { id: "x1", parent_id: "p9", delegate: true, status: "running" },
  ];
  assert.deepEqual(childrenSummary(parent, sessions), {
    total: 7,
    counts: { running: 2, waiting: 0, done: 1, failed: 2, stopped: 1, idle: 1 },
    live: 0,
    text: "⑂ 7",
    waitingText: null,
    title: "7 delegates: 2 running · 1 done · 2 failed · 1 stopped · 1 idle",
  });
});

test("childrenSummary: waiting is decided first: a running child with an open question or card waits, not runs", () => {
  const parent = { id: "p1" };
  const sessions = [
    { id: "c1", parent_id: "p1", delegate: true, status: "running", pending_question: { id: "q1", kind: "approval" } },
    { id: "c2", parent_id: "p1", delegate: true, status: "running" },
    { id: "c3", parent_id: "p1", delegate: true, status: "running", pending_card: { id: "k1" } },
  ];
  const sum = childrenSummary(parent, sessions);
  assert.deepEqual(sum.counts, { running: 1, waiting: 2, done: 0, failed: 0, stopped: 0, idle: 0 });
  assert.equal(sum.text, "⑂ 3");
  assert.equal(sum.waitingText, "2 waiting");
  assert.equal(sum.title, "3 delegates: 1 running · 2 waiting");
  assert.equal(childrenSummary(parent, sessions.slice(1, 2)).title, "1 delegate: 1 running");
});

test("delegatesSummary: the counter childrenSummary and the family chip share; live counts the worker-owned ones", () => {
  assert.equal(delegatesSummary([]), null);
  assert.equal(delegatesSummary(null), null);
  const sum = delegatesSummary([
    { id: "c1", status: "running", owner: "worker" },
    { id: "c2", status: "idle", owner: "worker", pending_question: { id: "q", kind: "question" } },
    { id: "c3", status: "idle", last_turn: { outcome: "completed" } },
  ]);
  assert.equal(sum.total, 3);
  assert.equal(sum.live, 2);
  assert.equal(sum.waitingText, "1 waiting");
  assert.equal(sum.title, "3 delegates: 1 running · 1 waiting · 1 done");
});

test("promptNotesChip: the names without model_notes_, the full line its tooltip; null without notes", () => {
  const notes = [
    { name: "model_notes_deepseek", scope: "system", chars: 612, digest: "0123456789ab" },
    { name: "model_notes_tidy", scope: "project", chars: 80, digest: "ba9876543210" },
  ];
  assert.deepEqual(promptNotesChip(notes), {
    text: "notes: deepseek, tidy",
    title: "model notes in this session's prompt: model_notes_deepseek (system, 612 chars), model_notes_tidy (project, 80 chars)",
  });
  assert.equal(promptNotesChip([]), null);
  assert.equal(promptNotesChip(undefined), null);
  assert.equal(promptNotesChip([{ scope: "system" }]), null);
});
