import test from "node:test";
import assert from "node:assert/strict";
import { previewOf, escapeHtml, messageBodyHtml, normalize } from "../../../lib/samagotchi/web/public/format.js";

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
