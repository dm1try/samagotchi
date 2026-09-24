import test from "node:test";
import assert from "node:assert/strict";
import { previewOf, relativeTime, escapeHtml, messageBodyHtml, normalize, modelLabel, userBodyHtml, noteHtml } from "../../../lib/samagotchi/web/public/format.js";

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

test("deleteConfirmText cuts a long preview and says a live worker is stopped first", () => {
  const text = deleteConfirmText({
    id: "3fa2b1c4-aaaa", short_id: "3fa2b1c4", first_preview: "x".repeat(80), owner: "worker",
  });
  assert.ok(text.startsWith(`Delete session 3fa2b1c4 — "${"x".repeat(40)}…"?`));
  assert.ok(text.endsWith("\nIts worker is running and will be stopped first."));
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
