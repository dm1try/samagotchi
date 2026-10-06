import test from "node:test";
import assert from "node:assert/strict";
import { emptyAnswerHtml, stateBadgeHtml, userBubbleHtml } from "../../../lib/samagotchi/web/public/turn_html.js";

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
