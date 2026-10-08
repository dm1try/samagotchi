import test from "node:test";
import assert from "node:assert/strict";
import { emptyAnswerHtml, stateBadgeHtml, statusParts, toolRowHtml, userBubbleHtml } from "../../../lib/samagotchi/web/public/turn_html.js";

test("userBubbleHtml: a plain prompt keeps its text as the copy source, its `>` lines as quotes", () => {
  assert.equal(userBubbleHtml({ content: "> quoted\nask" }),
    '<div class="bubble user" data-copy-source="&gt; quoted\nask"><div class="user-message"><blockquote>quoted</blockquote>ask</div></div>');
});

test("userBubbleHtml: a saved message's display is its copy source", () => {
  assert.match(userBubbleHtml({ role: "user", content: "a", display: "b" }), /data-copy-source="b"/);
});

test("userBubbleHtml: a steered line with its label, the step that read it, its thumbs and badge", () => {
  assert.equal(userBubbleHtml({ content: "also <this>" }, { label: "delegate report", state: "steered", step: "2", thumbs: '<div class="thumbs"></div>' }),
    '<div class="bubble user steered" data-user-state="steered" data-step="2" data-copy-source="also &lt;this&gt;">' +
    '<span class="origin-label">delegate report</span><div class="user-message">also &lt;this&gt;<div class="thumbs"></div></div>' +
    '<span class="state-badge">steered</span></div>');
});

test("userBubbleHtml: the live page's own fields, and a state without a badge is a plain bubble", () => {
  assert.equal(userBubbleHtml({ content: "hi  there" }, { state: "started", own: true, enqueuedId: "e\"1", key: "hi there" }),
    '<div class="bubble user" data-copy-source="hi  there" data-user-content="hi there" data-own="1" data-enqueued-id="e&quot;1">' +
    '<div class="user-message">hi  there</div></div>');
  assert.match(userBubbleHtml({ content: "x" }, { state: "queued" }), /^<div class="bubble user queued" data-user-state="queued".*<span class="state-badge">queued<\/span><\/div>$/);
  assert.match(userBubbleHtml({ content: "x" }, { state: "failed" }), /class="bubble user failed" data-user-state="failed"/);
});

test("userBubbleHtml: no content is an empty bubble, not 'undefined'", () => {
  assert.equal(userBubbleHtml({ content: undefined }), '<div class="bubble user" data-copy-source=""><div class="user-message"></div></div>');
});

test("stateBadgeHtml: only the named states", () => {
  assert.equal(stateBadgeHtml("queued"), '<span class="state-badge">queued</span>');
  assert.equal(stateBadgeHtml("started"), "");
  assert.equal(stateBadgeHtml(null), "");
});

test("emptyAnswerHtml: the muted notice with its retries, live (turn_summary) and reloaded alike", () => {
  assert.equal(emptyAnswerHtml({ retries: 1 }), '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing (after 1 retry)</div>');
  assert.equal(emptyAnswerHtml({ role: "empty_answer" }), '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing</div>');
});

test("statusParts: a row's status as a class, a label and the word only exceptions show", () => {
  assert.deepEqual(statusParts("ok"), { cls: "ok", label: "done", word: "" });
  assert.deepEqual(statusParts(undefined), { cls: "ok", label: "done", word: "" });
  assert.deepEqual(statusParts("running"), { cls: "running", label: "running", word: "" });
  assert.deepEqual(statusParts("error"), { cls: "error", label: "error", word: "error" });
  assert.deepEqual(statusParts("stopped"), { cls: "stopped", label: "stopped", word: "stopped" });
  assert.deepEqual(statusParts("blocked"), { cls: "blocked", label: "blocked", word: "blocked" });
});

test("toolRowHtml: a running row is its mark, tool and title, the command block, no output yet", () => {
  const row = { key: "1:1", tool: "execute", status: "running", params: 'command="ls"', title: "List", view: { command: "ls" }, output: "[execute]\nold" };
  const html = toolRowHtml(row);
  assert.match(html, /^<div class="activity-row" data-key="1:1"><span class="activity-status running" role="img" aria-label="running" title="running"><\/span><span class="activity-tool">execute<\/span><span class="activity-params" title="ls">List<\/span><div class="activity-command code-wrap">/);
  assert.doesNotMatch(html, /activity-output|activity-duration|activity-state/);
});

test("toolRowHtml: a done row has its duration, its output without the tool tag, cut at 300 with the rest on hover", () => {
  const out = `[read] ${"y".repeat(310)}`;
  const html = toolRowHtml({ key: "2:1", tool: "read", status: "ok", params: 'path="a"', output: out, duration_ms: 1200 });
  assert.equal(html,
    '<div class="activity-row" data-key="2:1"><span class="activity-status ok" role="img" aria-label="done" title="done"></span>' +
    '<span class="activity-tool">read</span><span class="activity-params">path=&quot;a&quot;</span><span class="activity-duration">1.2s</span>' +
    `<div class="activity-output" title="${"y".repeat(310)}">${"y".repeat(300)}…</div></div>`);
});

test("toolRowHtml: a call with no params has no empty title part; an error says so; images and a diff close the row", () => {
  const html = toolRowHtml({ key: "1:2", tool: "screenshot", label: "chrome: screenshot", status: "error", output: "", images: [{ file: "a.png" }], diff: { text: "@@", added: 1, removed: 0 } },
    { thumbs: (images) => `<div class="thumbs">${images.length}</div>` });
  assert.match(html, /<span class="activity-tool">chrome: screenshot<\/span><span class="activity-state error">error<\/span><div class="thumbs">1<\/div><details class="activity-diff">/);
  assert.doesNotMatch(html, /activity-params|activity-output/);
});

import { llmEditLine, toolRowInnerHtml } from "../../../lib/samagotchi/web/public/turn_html.js";

test("llmEditLine: a reloaded row's ✂ mark for each kind of LLM context edit", () => {
  assert.equal(llmEditLine({ kind: "stale", note: "superseded by a later read", tokens: 1002 }), "✂ stubbed: superseded by a later read · ~1.0k tokens");
  assert.equal(llmEditLine({ kind: "stale", note: "superseded by a later edit", tokens: 40 }), "✂ stubbed: superseded by a later edit · ~40 tokens");
  assert.equal(llmEditLine({ kind: "forget", note: "ls shows 3 files" }), "✂ forgotten: ls shows 3 files");
  assert.equal(llmEditLine({ kind: "forget", with: "t41", kept: "12-40" }), "✂ forgotten with t41 · lines 12-40 kept");
  assert.equal(llmEditLine({ kind: "forget", staged: true, note: "x" }), "✂ forget staged");
  assert.equal(llmEditLine(null), "");
  assert.equal(llmEditLine({ kind: "file" }), "");
});

test("toolRowInnerHtml: the ✂ mark goes above the output, its hover naming the output's id", () => {
  const html = toolRowInnerHtml({ key: "1:1", tool: "read", title: "a.rb", status: "ok", output: "[read]\nx", tool_id: "t1",
    edit: { kind: "forget", note: "a <b>" } });
  assert.match(html, /<div class="activity-edit" title="t1: ✂ forgotten: a &lt;b&gt;\nThe model is sent this instead of the output; the session keeps it.">✂ forgotten: a &lt;b&gt;<\/div><div class="activity-output"/);
  assert.doesNotMatch(toolRowInnerHtml({ key: "1:1", tool: "read", status: "ok" }), /activity-edit/);
});
