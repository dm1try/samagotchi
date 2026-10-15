import { canon, markupOf } from "./dom_shim.js";
import { html as lit } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  answerBubbleTemplate, badgeText, cancelLineTemplate, commandBubbleTemplate, elementOf, emptyAnswerTemplate, noteBubbleTemplate, shellCommandMessage,
  stateBadgeTemplate, statusParts, steerRowTemplate, toolRowTemplate, userBodyTemplate, userBubbleTemplate,
} from "../../../lib/samagotchi/web/public/turn_html.js";

// The templates' markup as the page gets it.
const toolRowHtml = (row, opts) => markupOf(toolRowTemplate(row, opts));
const userBubbleHtml = (m, opts) => markupOf(userBubbleTemplate(m, opts));
const commandBubbleHtml = (c) => markupOf(commandBubbleTemplate(c));
const stateBadgeHtml = (s, d) => markupOf(stateBadgeTemplate(s, d));
const emptyAnswerHtml = (i) => markupOf(emptyAnswerTemplate(i));
const noteHtml = (n) => markupOf(noteBubbleTemplate(n));
const userBodyHtml = (c) => markupOf(userBodyTemplate(c));
const steerRowHtml = (s, o) => markupOf(steerRowTemplate(s, o));
const answerBubbleHtml = (m, opts) => markupOf(answerBubbleTemplate(m, opts));

test("userBubbleTemplate: a plain prompt keeps its text as the copy source, its `>` lines as quotes", () => {
  assert.equal(userBubbleHtml({ content: "> quoted\nask" }),
    canon('<div class="bubble user" data-copy-source="&gt; quoted\nask"><div class="user-message"><blockquote>quoted</blockquote>ask</div></div>'));
});

test("userBubbleTemplate: a saved message's display is its copy source", () => {
  assert.match(userBubbleHtml({ role: "user", content: "a", display: "b" }), /data-copy-source="b"/);
});

test("userBubbleTemplate: a steered line with its label, the step that read it, its thumbs and badge", () => {
  assert.equal(userBubbleHtml({ content: "also <this>" }, { label: "delegate report", state: "steered", step: "2", thumbs: lit`<div class="thumbs"></div>` }),
    canon('<div class="bubble user steered" data-user-state="steered" data-step="2" data-copy-source="also &lt;this&gt;">' +
    '<span class="origin-label">delegate report</span><div class="user-message">also &lt;this&gt;<div class="thumbs"></div></div>' +
    '<span class="state-badge">steered</span></div>'));
});

test("userBubbleTemplate: the live page's own fields, and a state without a badge is a plain bubble", () => {
  assert.equal(userBubbleHtml({ content: "hi  there" }, { state: "started", own: true, enqueuedId: "e\"1", key: "hi there" }),
    '<div class="bubble user" data-copy-source="hi  there" data-user-content="hi there" data-own="1" data-enqueued-id="e&quot;1">' +
    '<div class="user-message">hi  there</div></div>');
  assert.match(userBubbleHtml({ content: "x" }, { state: "queued" }), /^<div class="bubble user queued" data-user-state="queued".*<span class="state-badge">queued<\/span><\/div>$/);
  assert.match(userBubbleHtml({ content: "x" }, { state: "failed" }), /class="bubble user failed" data-user-state="failed"/);
});

test("userBubbleTemplate: no content is an empty bubble, not 'undefined'", () => {
  assert.equal(userBubbleHtml({ content: undefined }), '<div class="bubble user" data-copy-source=""><div class="user-message"></div></div>');
});

test("shellCommandMessage: a `!cmd`'s saved message parses to its line and output; anything else is null", () => {
  assert.deepEqual(shellCommandMessage("!(echo hi)\nhi\n"), { line: "!echo hi", text: "hi\n" });
  assert.deepEqual(shellCommandMessage("!(cd x && rspec spec/c_spec.rb)\n3 examples, 0 failures\n"),
    { line: "!cd x && rspec spec/c_spec.rb", text: "3 examples, 0 failures\n" });
  // An empty output still parses (the newline is the shape).
  assert.deepEqual(shellCommandMessage("!(true)\n"), { line: "!true", text: "" });
  // A command with a ")" in it: the last ")" before the newline closes it.
  assert.deepEqual(shellCommandMessage("!(echo a)b)\nout"), { line: "!echo a)b", text: "out" });
  // No match: a normal message, one that merely starts with "!" or "!(",
  // one with no newline after the "!(" line, no content at all.
  assert.equal(shellCommandMessage("hello"), null);
  assert.equal(shellCommandMessage("! not a command"), null);
  assert.equal(shellCommandMessage("!(no newline"), null);
  assert.equal(shellCommandMessage("!(echo hi)"), null);
  assert.deepEqual(shellCommandMessage("!(echo hi)\n\nsecond line"), { line: "!echo hi", text: "\nsecond line" });
  assert.equal(shellCommandMessage(undefined), null);
  assert.equal(shellCommandMessage(null), null);
});

test("commandBubbleTemplate: the live page's command markup — the line, the output in a pre; HTML escaped", () => {
  assert.equal(commandBubbleHtml({ line: "!echo <hi>", text: "<hi> & \"bye\"\n" }),
    '<div class="bubble command"><div class="command-line">!echo &lt;hi&gt;</div>' +
    '<pre class="command-output">&lt;hi&gt; &amp; "bye"\n</pre></div>');
  // No output: no pre, as drawCommandBubble leaves it out.
  assert.equal(commandBubbleHtml({ line: "!true", text: "" }),
    '<div class="bubble command"><div class="command-line">!true</div></div>');
});

test("stateBadgeTemplate: only the named states", () => {
  assert.equal(stateBadgeHtml("queued"), '<span class="state-badge">queued</span>');
  assert.equal(stateBadgeHtml("started"), "");
  assert.equal(stateBadgeHtml(null), "");
});

test("emptyAnswerTemplate: the muted notice with its retries, live (turn_summary) and reloaded alike", () => {
  assert.equal(emptyAnswerHtml({ retries: 1 }), '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing (after 1 retry)</div>');
  assert.equal(emptyAnswerHtml({ role: "empty_answer" }), '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing</div>');
  assert.equal(emptyAnswerHtml({ retries: 0, refusal: { category: "cyber" } }), '<div class="bubble hook-notice empty-answer">no answer: refused by the provider (cyber)</div>');
});

test("statusParts: a row's status as a class, a label and the word only exceptions show", () => {
  assert.deepEqual(statusParts("ok"), { cls: "ok", label: "done", word: "" });
  assert.deepEqual(statusParts(undefined), { cls: "ok", label: "done", word: "" });
  assert.deepEqual(statusParts("running"), { cls: "running", label: "running", word: "" });
  assert.deepEqual(statusParts("error"), { cls: "error", label: "error", word: "error" });
  assert.deepEqual(statusParts("stopped"), { cls: "stopped", label: "stopped", word: "stopped" });
  assert.deepEqual(statusParts("blocked"), { cls: "blocked", label: "blocked", word: "blocked" });
});

test("toolRowTemplate: a running row is its mark, tool and title, the command block, no output yet", () => {
  const row = { key: "1:1", tool: "execute", status: "running", params: 'command="ls"', title: "List", view: { command: "ls" }, output: "[execute]\nold" };
  const html = toolRowHtml(row);
  assert.match(html, /^<div class="activity-row" data-key="1:1"><span class="activity-status running" role="img" aria-label="running" title="running"><\/span><span class="activity-tool">execute<\/span><span class="activity-params" title="ls">List<\/span><div class="activity-command code-wrap">/);
  assert.doesNotMatch(html, /activity-output|activity-duration|activity-state/);
});

test("toolRowTemplate: a call the model made under an alias's name says so, dim, after its title", () => {
  const html = toolRowHtml({ key: "1:1", tool: "execute", status: "ok", params: 'command="ls"', title: "List", called_as: "bash" });
  assert.match(html, /<span class="activity-params" title="command=&quot;ls&quot;">List<\/span><span class="activity-alias">\(called as bash\)<\/span>/);
  assert.doesNotMatch(toolRowHtml({ key: "1:1", tool: "execute", status: "ok", title: "List" }), /called as/);
});

test("toolRowTemplate: a built-in reached through call_tool says so, dim, after its title", () => {
  const html = toolRowHtml({ key: "1:1", tool: "delegate", status: "ok", params: 'task="look"', via: "call_tool" });
  assert.match(html, /<span class="activity-tool">delegate<\/span><span class="activity-params"[^>]*>task="look"<\/span><span class="activity-alias">\(via call_tool\)<\/span>/);
  assert.doesNotMatch(toolRowHtml({ key: "1:1", tool: "delegate", status: "ok" }), /via call_tool/);
});

test("toolRowTemplate: a read row with a ref adds its numbered lines under the preview, closed", () => {
  const html = toolRowHtml({ key: "2:2", tool: "read", status: "ok", title: "a.rb", ref: { kind: "file", path: "/p/a.rb" }, output: "[read]\n  x\n" });
  assert.match(html, /<div class="activity-output" title="x\n">x\n<\/div><details class="activity-read"><summary>line 1<\/summary>/);
  assert.match(html, /<span class="read-line" data-line="1">  x<\/span>/);
});

test("toolRowTemplate: a done row has its duration, its output without the tool tag, cut at 300 with the rest on hover", () => {
  const out = `[read] ${"y".repeat(310)}`;
  const html = toolRowHtml({ key: "2:1", tool: "read", status: "ok", params: 'path="a"', output: out, duration_ms: 1200 });
  assert.equal(html,
    '<div class="activity-row" data-key="2:1"><span class="activity-status ok" role="img" aria-label="done" title="done"></span>' +
    '<span class="activity-tool">read</span><span class="activity-params">path="a"</span><span class="activity-duration">1.2s</span>' +
    `<div class="activity-output" title="${"y".repeat(310)}">${"y".repeat(300)}…</div></div>`);
});

test("toolRowTemplate: a call with no params has no empty title part; an error says so; images and a diff close the row", () => {
  const html = toolRowHtml({ key: "1:2", tool: "screenshot", label: "chrome: screenshot", status: "error", output: "", images: [{ file: "a.png" }], diff: { text: "@@", added: 1, removed: 0 } },
    { thumbs: (images) => lit`<div class="thumbs">${images.length}</div>` });
  assert.match(html, /<span class="activity-tool">chrome: screenshot<\/span><span class="activity-state error">error<\/span><div class="thumbs">1<\/div><details class="activity-diff">/);
  assert.doesNotMatch(html, /activity-params|activity-output/);
});

import { llmEditLine, toolRowInnerTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";

const toolRowInnerHtml = (row, opts) => markupOf(toolRowInnerTemplate(row, opts));

test("llmEditLine: a reloaded row's ✂ mark for each kind of LLM context edit", () => {
  assert.equal(llmEditLine({ kind: "stale", note: "superseded by a later read", tokens: 1002 }), "✂ stubbed: superseded by a later read · ~1.0k tokens");
  assert.equal(llmEditLine({ kind: "stale", note: "superseded by a later edit", tokens: 40 }), "✂ stubbed: superseded by a later edit · ~40 tokens");
  assert.equal(llmEditLine({ kind: "forget", note: "ls shows 3 files" }), "✂ forgotten: ls shows 3 files");
  assert.equal(llmEditLine({ kind: "forget", with: "t41", kept: "12-40" }), "✂ forgotten with t41 · lines 12-40 kept");
  assert.equal(llmEditLine({ kind: "forget", staged: true, note: "x" }), "✂ forget staged");
  assert.equal(llmEditLine(null), "");
  assert.equal(llmEditLine({ kind: "file" }), "");
});

test("toolRowInnerTemplate: the ✂ mark goes above the output, its hover naming the output's id", () => {
  const html = toolRowInnerHtml({ key: "1:1", tool: "read", title: "a.rb", status: "ok", output: "[read]\nx", tool_id: "t1",
    edit: { kind: "forget", note: "a <b>" } });
  assert.match(html, /<div class="activity-edit" title="t1: ✂ forgotten: a <b>\nThe model is sent this instead of the output; the session keeps it.">✂ forgotten: a &lt;b&gt;<\/div><div class="activity-output"/);
  assert.doesNotMatch(toolRowInnerHtml({ key: "1:1", tool: "read", status: "ok" }), /activity-edit/);
});

test("statusParts / toolRowHtml: a grep's no-match is done, with a muted 'no match' word of its own class", () => {
  assert.deepEqual(statusParts("ok", { noMatch: true }), { cls: "ok", label: "done", word: "no match", wordCls: "no-match" });
  assert.deepEqual(statusParts("error", { noMatch: true }), { cls: "error", label: "error", word: "error" });
  const html = toolRowHtml({ key: "1:1", tool: "execute", status: "ok", no_match: true, title: "rg zzz", output: "[execute]\nexit: 1 (no output)" });
  assert.match(html, /<span class="activity-status ok" role="img" aria-label="done" title="done"><\/span>/);
  assert.match(html, /<span class="activity-state no-match">no match<\/span>/);
  assert.match(html, /exit: 1 \(no output\)/);
  assert.doesNotMatch(toolRowHtml({ key: "1:1", tool: "execute", status: "ok", title: "ls" }), /no match/);
});

test("noteBubbleTemplate: who sent the context note, then its text, both escaped", () => {
  assert.equal(
    noteHtml({ label: "session 3f2a1c (~/p/<x>)", content: "a <b>\nc" }),
    '<div class="bubble note"><div class="note-line">note from session 3f2a1c (~/p/&lt;x&gt;)</div><div class="note-text">a &lt;b&gt;\nc</div></div>',
  );
  assert.equal(noteHtml({ content: "x" }), '<div class="bubble note"><div class="note-line">note</div><div class="note-text">x</div></div>');
});

test("answerBubbleTemplate only uses explicitly rendered assistant HTML, set whole (no lit markers inside)", () => {
  assert.equal(answerBubbleHtml({ role: "assistant", content: "**safe**", html: "<strong>safe</strong>" }, { at: 3 }),
    '<div class="bubble output markdown" data-answer-at="3" data-copy-source="**safe**"><strong>safe</strong></div>');
  assert.equal(answerBubbleHtml({ role: "assistant", content: "<img>" }), '<div class="bubble output">&lt;img&gt;</div>');
  assert.equal(answerBubbleHtml({ role: "assistant", content: "a", display: "[a](u)", html: "<p>a</p>" }, { cls: " report-reply" }),
    '<div class="bubble output report-reply markdown" data-copy-source="[a](u)"><p>a</p></div>');
  // The bubble's nodes as the live turn end leaves them: no comment inside.
  const el = elementOf(answerBubbleTemplate({ role: "assistant", content: "x", html: "<p>x</p>" }));
  assert.equal(el.innerHTML, "<p>x</p>");
});

test("userBodyTemplate leaves a message without quotes as escaped text", () => {
  assert.equal(userBodyHtml("a <b>\n\n  c"), "a &lt;b&gt;\n\n  c");
  assert.equal(userBodyHtml(undefined), "");
});

test("userBodyTemplate turns runs of > lines into blockquotes", () => {
  assert.equal(
    userBodyHtml("From your thinking:\n> one <x>\n>two\n\nwhy?\n\n> three\n\nok"),
    "From your thinking:<blockquote>one &lt;x&gt;\ntwo</blockquote>why?<blockquote>three</blockquote>ok",
  );
});

test("userBodyTemplate keeps an empty quote line and handles CRLF", () => {
  assert.equal(userBodyHtml("> a\r\n>\r\n> b\r\n\r\nnote"), "<blockquote>a\n\nb</blockquote>note");
});

test("answerBubbleTemplate: a user message's html is ignored, its quotes render", () => {
  assert.equal(answerBubbleHtml({ role: "user", content: "<img>", html: "<strong>ignored</strong>" }),
    '<div class="bubble output" data-copy-source="<img>">&lt;img&gt;</div>');
  assert.equal(answerBubbleHtml({ role: "user", content: "> q\n\nn" }),
    canon('<div class="bubble output" data-copy-source="&gt; q\n\nn"><blockquote>q</blockquote>n</div>'));
});

test("steerRowTemplate: who nudged the model, the text collapsed and escaped; a bubble on its own", () => {
  assert.equal(steerRowHtml({ source: "check-in", text: "a <b>" }),
    '<details class="steer-row"><summary>check-in nudged the model</summary><div class="steer-text">a &lt;b&gt;</div></details>');
  assert.match(steerRowHtml({ text: "x" }, { bubble: true }), /^<details class="bubble steer-row"><summary>nudged the model</);
});

test("cancelLineTemplate: the line a re-render draws from a canceled turn's record, nothing for another", () => {
  assert.equal(markupOf(cancelLineTemplate({ status: "canceled", cancellation_reason: "ctrl_c" })), '<div class="bubble cancel stopped">\u25A0 canceled (Ctrl-C)</div>');
  assert.equal(markupOf(cancelLineTemplate({ status: "canceled" })), '<div class="bubble cancel stopped">\u25A0 canceled</div>');
  assert.equal(markupOf(cancelLineTemplate({ status: "canceled", cancellation_reason: "<x>" })), '<div class="bubble cancel stopped">\u25A0 canceled (&lt;x&gt;)</div>');
  assert.equal(markupOf(cancelLineTemplate({ status: "canceled", cancellation_reason: "hook", cancelled_by: "loop-guard" })),
    '<div class="bubble cancel stopped">\u25A0 stopped by loop-guard</div>');
  assert.equal(markupOf(cancelLineTemplate({ status: "completed" })), "");
  assert.equal(markupOf(cancelLineTemplate(null)), "");
});

test("elementOf: a template's one element, to change by hand (the live bubble's badge)", () => {
  const el = elementOf(userBubbleTemplate({ content: "hi" }, { state: "queued" }));
  assert.equal(el.tagName, "DIV");
  assert.equal(el.querySelector(".state-badge").textContent, "queued");
  el.querySelector(".state-badge").remove();
  el.append(elementOf(stateBadgeTemplate("steered")));
  assert.equal(el.querySelector(".state-badge").textContent, "steered");
});

test("badgeText: a queued line says what it waits for by its delivery; the other states as named", () => {
  assert.equal(badgeText("queued", "next_step"), "waits for the next step");
  assert.equal(badgeText("queued", "cut"), "cutting in\u2026");
  assert.equal(badgeText("queued", "queue"), "after this turn");
  assert.equal(badgeText("queued", null), "queued");
  assert.equal(badgeText("steered", "cut"), "steered");
  assert.equal(badgeText("started", "queue"), null);
  assert.equal(stateBadgeHtml("queued", "queue"), '<span class="state-badge">after this turn</span>');
});

test("userBubbleTemplate: a line's delivery is its data-delivery, and its badge's words", () => {
  const out = userBubbleHtml({ content: "later" }, { state: "queued", delivery: "queue", own: true });
  assert.match(out, /data-delivery="queue"/);
  assert.match(out, /<span class="state-badge">after this turn<\/span>/);
  assert.doesNotMatch(userBubbleHtml({ content: "x" }, { state: "queued" }), /data-delivery/);
});

import { inlineOutput, tailMode } from "../../../lib/samagotchi/web/public/turn_html.js";

const lines = (n, width = 9) => Array.from({ length: n }, (_, i) => `line ${String(i + 1).padStart(width - 5, "0")}`).join("\n");

test("inlineOutput: a long execute shows its end from a line start, without the success exit line", () => {
  const full = `stdout:\n${lines(80)}\n\nexit: 0`;
  const shown = inlineOutput("execute", full);
  assert.ok(shown.startsWith("…line "), shown);
  assert.ok(shown.endsWith("line 0080"), shown);
  assert.ok(shown.length <= 301);
  assert.doesNotMatch(shown, /exit: 0|stdout:/);
});

test("toolRowTemplate: a failed long execute shows its tail and exit line next to the red mark (its div scrolled to the end), all of it on hover", () => {
  const out = `[execute]\nstdout:\n${lines(80)}\n\nexit: 1`;
  const html = toolRowHtml({ key: "1:1", tool: "execute", status: "error", title: "rspec", output: out });
  assert.match(html, /<span class="activity-status error" role="img" aria-label="error" title="error"><\/span>/);
  assert.match(html, /<span class="activity-state error">error<\/span>/);
  assert.match(html, /<div class="activity-output tail" title="stdout:\nline 0001\n[^"]*exit: 1">…line [^<]*line 0080\n\nexit: 1<\/div>/);
});

test("inlineOutput: a short execute drops the lone stdout label and exit: 0; with stderr both labels stay", () => {
  assert.equal(inlineOutput("execute", "stdout:\nok\n\nexit: 0"), "ok");
  assert.equal(inlineOutput("execute", "stdout:\nok\n\nstderr:\nwarn\n\nexit: 0"), "stdout:\nok\n\nstderr:\nwarn");
  assert.equal(inlineOutput("execute", "stderr:\nboom\n\nexit: 2"), "stderr:\nboom\n\nexit: 2");
});

test("inlineOutput: a long stdout and stderr keep the stderr label and the exit line", () => {
  const full = `stdout:\n${lines(40)}\n\nstderr:\n${lines(20)}\n\nexit: 1`;
  const shown = inlineOutput("execute", full);
  assert.match(shown, /^…/);
  assert.match(shown, /\nstderr:\n/);
  assert.ok(shown.endsWith("line 0020\n\nexit: 1"), shown);
});

test("inlineOutput: no output, a bare exit: 0 and a whitespace-only stdout stay as they are; a hint after exit: 0 stays", () => {
  assert.equal(inlineOutput("execute", "exit: 0 (no output)"), "exit: 0 (no output)");
  assert.equal(inlineOutput("execute", "exit: 0"), "exit: 0");
  assert.equal(inlineOutput("execute", "stdout:\n  \n\nexit: 0"), "stdout:\n  \n\nexit: 0");
  assert.equal(inlineOutput("execute", "stdout:\nok\n\nexit: 0\n(started in the background)"), "ok\n\n(started in the background)");
  assert.equal(inlineOutput("execute", "exit: 1"), "exit: 1");
});

test("tailMode: a signal-killed execute's exit line (\"exit: \" with no number) takes the tail path as exit: 1 does", () => {
  assert.equal(tailMode("execute", "[execute]\nexit: "), true);
  assert.equal(tailMode("execute", "[execute]\nexit: 1"), true);
  assert.equal(tailMode("execute", "[execute]\nsome text"), false);
});

test("inlineOutput: a gate-corrected call's ran-as line and tag show on hover only", () => {
  assert.equal(inlineOutput("execute", "ran as: execute ls\n[execute]\nstdout:\nok\n\nexit: 0"), "ok");
  assert.equal(inlineOutput("read", 'ran as: read path="a"\n[read]\nx'), "x");
  const html = toolRowHtml({ key: "1:1", tool: "execute", status: "ok", title: "ls",
    output: "ran as: execute ls\n[execute]\nstdout:\nok\n\nexit: 0" });
  assert.match(html, /<div class="activity-output tail" title="ran as: execute ls\n\[execute\]\nstdout:\nok\n\nexit: 0">ok<\/div>/);
});

test("inlineOutput: a cut gap line before a short tail is kept like any other line", () => {
  const full = `stdout:\n${lines(30)}\n[cut: lines 31-900 not shown]\nsummary: 3 failures\n\nexit: 1`;
  const shown = inlineOutput("execute", full);
  assert.ok(shown.endsWith("[cut: lines 31-900 not shown]\nsummary: 3 failures\n\nexit: 1"), shown);
});

test("inlineOutput: tail mode mirrors clip's length: 301 chars whole, 302 cut to … and the last 300, from a line start", () => {
  const body = (n) => `stdout:\n${"z".repeat(n - "\n\nexit: 1".length)}\n\nexit: 1`;
  assert.equal(inlineOutput("execute", body(301)), body(301).slice("stdout:\n".length));
  assert.equal(inlineOutput("execute", body(302)), `…${body(302).slice(-300)}`);
  const lined = `stderr:\n${"z".repeat(100)}\n${"w".repeat(200)}\n\nexit: 1`;
  assert.equal(inlineOutput("execute", lined), `…${"w".repeat(200)}\n\nexit: 1`);
});

test("inlineOutput: one long line is cut mid-line; an emoji at the cut isn't split", () => {
  const long = `stdout:\n${"a".repeat(400)}\n\nexit: 1`;
  assert.equal(inlineOutput("execute", long), `…${long.slice(-300)}`);
  const text = `stdout:\n${"b".repeat(200)}😀${"c".repeat(290)}\n\nexit: 1`;
  const cutAt = text.length - 300;
  assert.equal(text.charCodeAt(cutAt) >= 0xdc00 && text.charCodeAt(cutAt) <= 0xdfff, true);
  assert.equal(inlineOutput("execute", text), `…${text.slice(cutAt + 1)}`);
});

test("inlineOutput: a hand-over, a guardrail deny and an error keep their head", () => {
  const handOver = `Still running at the 120s limit: moved to a background task, not killed.\ntask_id: t1\nWait for it with task_wait.\nstdout (so far, tail):\n${lines(60)}`;
  assert.equal(inlineOutput("execute", handOver), `${handOver.slice(0, 300)}…`);
  const denied = `Error: denied by guardrail (rm -rf): ${"reason ".repeat(60)}Do not retry it.`;
  assert.equal(inlineOutput("execute", denied), `${denied.slice(0, 300).trimEnd()}…`);
  const error = `Error: ${"boom ".repeat(80)}`;
  assert.equal(inlineOutput("execute", error), `${error.slice(0, 300).trimEnd()}…`);
});

test("inlineOutput: a task_wait with its log's tail shows the end; one with its record lines only, read and other tools the start", () => {
  const waited = `task_id: t1\nstatus: running\nexit_code:\nwait_result: timeout\noutput_tail:\n${lines(60)}\n`;
  const shown = inlineOutput("task_wait", waited);
  assert.ok(shown.startsWith("…") && shown.endsWith("line 0060"), shown);
  const record = `task_id: t1\nstatus: completed\nexit_code: 0\nstop_reason:\noutput_path: /${"p".repeat(300)}/out.log`;
  assert.equal(inlineOutput("task_wait", record), `${record.slice(0, 300)}…`);
  const other = `stdout:\n${lines(60)}\n\nexit: 0`;
  assert.equal(inlineOutput("read", other), `${other.slice(0, 300)}…`);
  assert.equal(inlineOutput("delegate", other), `${other.slice(0, 300)}…`);
});

test("toolRowTemplate: a head-mode output has no tail class", () => {
  const html = toolRowHtml({ key: "1:1", tool: "execute", status: "blocked", output: "[execute] Error: denied by guardrail (rm): no" });
  assert.match(html, /<div class="activity-output" title="Error: denied by guardrail \(rm\): no">/);
});
