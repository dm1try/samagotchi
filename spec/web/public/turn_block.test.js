// turnHistoryNodes: a reloaded history as chi web sends it, every finished
// turn drawn (drawn_history.js stamps the items and gives each turn a
// minimal drawing). What a drawing holds and how a drawn turn's block,
// rows, notices and end come out is turn_drawing.test.js's and the parity
// test's (turn_drawing_parity.test.js); here: the saved items' overlays
// (an answer's markdown, refs and key, a step's text, the timing line,
// merged lines, a report's label and reply, the gap dividers) and
// what sits between the turns (notes, `!cmd` records).
import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { stepText, turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { answerRefsOf } from "../../../lib/samagotchi/web/public/answer_refs.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";
import { drawnHistory } from "./drawn_history.js";

const thumbs = () => "";

// The nodes for +source+ items as chi web's show draws them.
function history(source, timing = normalizeTiming({}), { ends, ...opts } = {}) {
  const { items, drawings } = drawnHistory(source, { ends });
  return turnHistoryNodes(items, timing, { thumbs, drawings, ...opts });
}
const historyHtml = (...args) => htmlOf(history(...args));
// The nodes in a holder, as returned (a clone would drop the WeakMap's data).
function held(...args) {
  const holder = document.createElement("div");
  holder.append(history(...args));
  return holder;
}

test("a plain answer and a note; the timing line under the answer, where the live view leaves it", () => {
  const items = [{ role: "user", content: "p", turn_id: "T1" }, { role: "assistant", content: "PONG" }, { role: "note", content: "n", label: "x" }];
  const html = historyHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }] }));
  assert.match(html, /^<div class="bubble user"[^>]*data-turn-id="T1"[^>]*><div class="user-message">p<\/div><\/div>/);
  assert.match(html, /<div class="bubble output" data-answer-turn="T1"[^>]*>PONG<\/div><div class="turn-timing"[^>]*>turn 1 · 0.5s<\/div>/);
  assert.match(html, /<div class="bubble note"><div class="note-line">note from x<\/div><div class="note-text">n<\/div><\/div>$/);
});

test("a `!cmd`'s saved user message renders as its command bubble, not a user bubble", () => {
  const html = historyHtml([{ role: "user", content: "!(echo <hi>)\n<hi>" }, { role: "assistant", content: "done" }]);
  assert.match(html, /^<div class="bubble command"><div class="command-line">!echo &lt;hi&gt;<\/div><pre class="command-output">&lt;hi&gt;<\/pre><\/div>/);
  assert.doesNotMatch(html, /bubble user/);
  // A message that merely starts with "!(" without the newline shape stays a user bubble.
  assert.match(historyHtml([{ role: "user", content: "!(no newline" }]), /^<div class="bubble user"/);
});

test("a `!cmd`'s record between two prompts is its bubble alone: no steps, no timing; the next turn's shows once", () => {
  const items = [
    { role: "user", content: "one", turn_id: "T1" }, { role: "assistant", content: "1" },
    { role: "user", content: "!(basket open)\nstderr: x" },
    { role: "user", content: "two", turn_id: "T2" },
    { role: "assistant", content: "", parts: { tools: [{ tool: "execute", params: 'command="true"', output: "ok" }] } },
    { role: "assistant", content: "2" },
  ];
  const twoTurns = normalizeTiming({ turn_records: [{ id: "T1", status: "completed", duration_ms: 1000 }, { id: "T2", status: "completed", duration_ms: 13000 }] });
  const out = history(items, twoTurns);
  const kids = [...out.children].map((el) => el.className.split(" ").slice(0, 2).join(" "));
  assert.deepEqual(kids, ["bubble user", "bubble output", "turn-timing", "bubble command", "bubble user", "turn-work done", "bubble output", "turn-timing"]);
  assert.deepEqual([...out.querySelectorAll(".turn-timing")].map((el) => el.textContent), ["turn 1 · 1.0s", "turn 2 · 13s"]);
  assert.equal(out.querySelector(".bubble.command").dataset.drawn, undefined);
});

test("the user's lines merged into a turn stay in it: a steered bubble after its steps, before its answer and timing", () => {
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "Let me check.", parts: { tools: [{ tool: "read", params: 'path="a"', output: "x" }] } },
    { role: "user", content: "also <typos>", merged: true, step: 2 },
    { role: "assistant", content: "Both fine." },
    { role: "user", content: "next", turn_id: "T2" },
    { role: "assistant", content: "ok" },
  ];
  const twoTurns = normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5000 }, { id: "T2", duration_ms: 2000 }] });
  const html = historyHtml(items, twoTurns);
  assert.equal((html.match(/class="bubble user"/g) || []).length, 2);
  assert.match(html, /<\/details><div class="bubble user steered" data-user-state="steered" data-step="2".*?><div class="user-message">also &lt;typos&gt;<\/div><span class="state-badge">steered<\/span><\/div><div class="bubble output[^"]*"[^>]*>.*Both fine.*<\/div><div class="turn-timing"[^>]*>turn 1 · 5\.0s<\/div>/);
  assert.match(html, /ok.*<div class="turn-timing"[^>]*>turn 2 · 2\.0s<\/div>/);
});

test("a delegate report keeps its label on reload: a wake turn's prompt, or merged into a turn", () => {
  const items = [
    { role: "user", content: "session: c1", source: "delegate_report", turn_id: "T1" },
    { role: "assistant", content: "The child found it." },
    { role: "user", content: "p", turn_id: "T2" },
    { role: "assistant", content: "Let me check.", parts: { tools: [{ tool: "read", params: 'path="a"', output: "x" }] } },
    { role: "user", content: "session: c2", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "Both fine." },
  ];
  const html = historyHtml(items);
  assert.match(html, /^<div class="bubble user"[^>]*><span class="origin-label">delegate report<\/span><div class="user-message">session: c1<\/div>/);
  assert.match(html, /<div class="bubble user steered"[^>]*><span class="origin-label">delegate report<\/span><div class="user-message">session: c2/);
  assert.equal((html.match(/origin-label/g) || []).length, 2);
  // Their source and fold keys (answer_fold.js): the wake turn's by its turn id, the merged one by its place.
  assert.match(html, /^<div class="bubble user"[^>]*data-turn-id="T1"[^>]*data-source="delegate_report"[^>]*>/);
  assert.match(html, /<div class="bubble user steered"[^>]*data-source="delegate_report" data-line-key="T2:input:2"[^>]*>/);
  // A merged line that isn't a report has no line key.
  assert.doesNotMatch(historyHtml([items[2], items[3], { role: "user", content: "also", merged: true, step: 2 }, items[5]]), /data-line-key/);
});

test("the text that answered a delegate report mid-turn stays visible after its bubble, unless it is the answer", () => {
  const read = { tools: [{ tool: "read", params: 'path="a"', output: "x" }] };
  const items = [
    { role: "user", content: "rename it", turn_id: "T1" },
    { role: "assistant", content: "Reading.", parts: read },
    { role: "user", content: "session: c1", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "The delegate found the bug. Back to the rename.", parts: read },
    { role: "assistant", content: "Renamed." },
    { role: "user", content: "next", turn_id: "T2" },
    { role: "assistant", content: "Reading.", parts: read },
    { role: "user", content: "session: c2", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "Done; the delegate said ok." },
  ];
  const html = historyHtml(items);
  assert.match(html, /session: c1<\/div><span class="state-badge">steered<\/span><\/div><div class="bubble output report-reply"[^>]*>The delegate found the bug\. Back to the rename\.<\/div>.*<div class="bubble output[^"]*"[^>]*>Renamed\./);
  assert.equal((html.match(/report-reply/g) || []).length, 1);
  // Its own fold key (answer_fold.js): the turn's id and the report's place after the opening.
  assert.match(html, /class="bubble output report-reply"[^>]*data-reply-key="T1:report:2"/);
  assert.doesNotMatch(html, /report-reply"[^>]*data-answer-turn/);
});

test("the timing line numbers a turn by its record, after a failed turn as live", () => {
  const timing = normalizeTiming({ turn_records: [
    { id: "A", status: "completed", duration_ms: 1000 },
    { id: "B", status: "failed", duration_ms: 50 },
    { id: "C", status: "completed", duration_ms: 3000 },
  ] });
  const items = [
    { role: "user", content: "one", turn_id: "A" }, { role: "assistant", content: "1" },
    { role: "user", content: "three", turn_id: "C" }, { role: "assistant", content: "3" },
  ];
  const html = historyHtml(items, timing);
  assert.match(html, /turn 1 · 1\.0s/);
  assert.match(html, /turn 3 · 3\.0s/);
});

test("a context wake turn starts with its note (turn_start): the note bubble, then its own answer (keyed by its turn) and timing", () => {
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "PONG" },
    { role: "note", content: "Updated: pr-1.", label: "context pr-1", turn_start: true, turn_id: "T2" },
    { role: "assistant", content: "Bob asked for changes." },
  ];
  const two = normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }, { id: "T2", duration_ms: 2000 }] });
  assert.match(historyHtml(items, two),
    /<div class="bubble note turn-start" data-opening-id="T2"[^>]*><div class="note-line">note from context pr-1<\/div><div class="note-text">Updated: pr-1.<\/div><\/div><div class="bubble output" data-answer-turn="T2"[^>]*>Bob asked for changes.<\/div><div class="turn-timing"[^>]*>turn 2 · 2.0s<\/div>$/);
});

test("a turn's answer carries its turn id (data-answer-turn); a report reply, a turn with no opening and one saved without an id don't", () => {
  const read = { tools: [{ tool: "read", params: 'path="a"', output: "x" }] };
  const items = [
    { role: "assistant", content: "hello" },
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "Reading.", parts: read },
    { role: "user", content: "session: c1", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "The report says done.", parts: read },
    { role: "user", content: "next", merged: true, step: 3 },
    { role: "assistant", content: "Final." },
    { role: "user", content: "old" },
    { role: "assistant", content: "Old answer." },
  ];
  const keys = [...history(items).querySelectorAll(".bubble.output")].map((el) => [el.textContent, el.dataset.answerTurn ?? null]);
  assert.deepEqual(keys, [["hello", null], ["The report says done.", null], ["Final.", "T1"], ["Old answer.", null]]);
});

test("an answer bubble knows its message's display_refs (no index left in the DOM); one without has none", () => {
  const refs = [{ match: "JIRA-7", kind: "issue", target: { id: "JIRA-7" }, actions: [] }];
  const reply = [{ match: "ABC-3", kind: "issue", target: { id: "ABC-3" }, actions: [] }];
  const read = { tools: [{ tool: "read", params: 'path="a"', output: "x" }] };
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "First, JIRA-7.", display_refs: refs },
    { role: "user", content: "q", turn_id: "T2" },
    { role: "assistant", content: "Reading.", parts: read },
    { role: "user", content: "session: c1", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "Report says ABC-3.", display_refs: reply, parts: read },
    { role: "assistant", content: "Plain." },
  ];
  const holder = held(items);
  const bubbles = [...holder.querySelectorAll(".bubble.output")];
  assert.deepEqual(bubbles.map((b) => b.textContent), ["First, JIRA-7.", "Report says ABC-3.", "Plain."]);
  assert.deepEqual(bubbles.map((b) => answerRefsOf(b)), [refs, reply, null]);
  assert.ok(holder.querySelector("[data-answer-at]") === null);
});

test("a step's text knows its message's display_refs (a question's), as an answer does", () => {
  const refs = [{ match: "DEMO-123", kind: "issue", target: { id: "DEMO-123" }, actions: [] }];
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "Proceed with DEMO-123?", display_refs: refs, parts: { tools: [{ tool: "ask_user_question", params: "", output: "a" }] } },
    { role: "assistant", content: "Reading.", parts: { tools: [{ tool: "read", params: 'path="R.md"', output: "[read]\nok" }] } },
    { role: "assistant", content: "Done." },
  ];
  const holder = held(items);
  const texts = [...holder.querySelectorAll(".gen > .gen-text")];
  assert.deepEqual(texts.map((el) => el.textContent), ["Proceed with DEMO-123?", "Reading."]);
  assert.deepEqual(texts.map((el) => answerRefsOf(el)), [refs, null]);
  assert.ok(holder.querySelector("[data-answer-at]") === null);
});

test("a step's text with its message's rendered markdown shows it, keeping the text as written for stepText", () => {
  const refs = [{ match: "DEMO-123", kind: "issue", target: { id: "DEMO-123" }, actions: [] }];
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "Proceed with **DEMO-123**?", html: "<p>Proceed with <strong>DEMO-123</strong>?</p>", display_refs: refs, parts: { tools: [{ tool: "ask_user_question", params: "", output: "a" }] } },
    { role: "assistant", content: "Plain step.", parts: { tools: [{ tool: "read", params: 'path="R.md"', output: "[read]\nok" }] } },
    { role: "assistant", content: "Done.", html: "<p>Done.</p>" },
  ];
  const holder = held(items);
  const [md, plain] = holder.querySelectorAll(".gen > .gen-text");
  assert.ok(md.classList.contains("markdown") && md.classList.contains("md-compact"));
  assert.equal(md.querySelector("strong").textContent, "DEMO-123");
  assert.deepEqual(answerRefsOf(md), refs);
  assert.ok(!plain.classList.contains("markdown"));
  assert.equal(plain.textContent, "Plain step.");
  assert.equal(stepText(holder.querySelector(".turn-work"), 1), "Proceed with **DEMO-123**?");
});

test("stepText: a reloaded block's step text by iteration (1-based), \"\" for a step without text or none at all", () => {
  const read = { tools: [{ tool: "read", params: 'path="a"', output: "x" }] };
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "I found two files.\nThey disagree.", parts: read },
    { role: "assistant", content: "", parts: read },
    { role: "assistant", content: "Done." },
  ];
  const block = held(items).querySelector(".turn-work");
  assert.equal(stepText(block, 1), "I found two files.\nThey disagree.");
  assert.equal(stepText(block, 2), "");
  assert.equal(stepText(block, 7), "");
  assert.equal(stepText(null, 1), "");
});

test("a gap divider between turns 10+ quiet minutes apart (its own element), and each bubble's time on hover", () => {
  const at = (h, m) => new Date(2026, 9, 24, h, m).toISOString();
  const items = [
    { role: "user", content: "one", turn_id: "T1", at: at(9, 0) },
    { role: "assistant", content: "first", at: at(9, 1) },
    { role: "user", content: "two", turn_id: "T2", at: at(9, 5) },
    { role: "assistant", content: "second", at: at(9, 6) },
    { role: "note", content: "deploy frozen", label: "slack", at: at(9, 36) },
    { role: "user", content: "three", turn_id: "T3", at: at(9, 40) },
    { role: "assistant", content: "third", at: at(9, 41) },
  ];
  const holder = held(items, normalizeTiming({}), { now: new Date(2026, 9, 24, 23, 0).getTime() });
  const gaps = [...holder.querySelectorAll(".time-gap")];
  assert.deepEqual(gaps.map((el) => el.textContent), ["── 09:36 · 30 min later ──"]);
  assert.ok(gaps[0].nextElementSibling.matches(".bubble.note"));
  assert.ok(!gaps[0].matches(".bubble, .turn-work"));
  assert.equal(holder.querySelector(".bubble.user").getAttribute("title"), "Sat 24 Oct 2026 09:00:00");
  assert.equal(holder.querySelector(".bubble.output").getAttribute("title"), "Sat 24 Oct 2026 09:01:00");
  assert.equal(holder.querySelector(".bubble.note").getAttribute("title"), "Sat 24 Oct 2026 09:36:00");
  // Unstamped (an old session): no title, no divider.
  const old = held([{ role: "user", content: "x", turn_id: "T1" }, { role: "assistant", content: "y" }]);
  assert.equal(old.querySelector(".bubble.user").hasAttribute("title"), false);
  assert.ok(old.querySelector(".time-gap") === null);
});

test("an old session's turns get their divider from the turn records (started_at, duration_ms)", () => {
  const at = (h, m) => new Date(2026, 9, 24, h, m).toISOString();
  const items = [{ role: "user", content: "one", turn_id: "T1" }, { role: "assistant", content: "a" },
    { role: "user", content: "two", turn_id: "T2" }, { role: "assistant", content: "b" }];
  const records = normalizeTiming({ turn_records: [
    { id: "T1", status: "completed", started_at: at(9, 0), duration_ms: 60_000 },
    { id: "T2", status: "completed", started_at: at(11, 1), duration_ms: 60_000 },
  ] });
  const holder = held(items, records, { now: new Date(2026, 9, 24, 23, 0).getTime() });
  assert.deepEqual([...holder.querySelectorAll(".time-gap")].map((el) => el.textContent), ["── 11:01 · 2 h later ──"]);
  assert.ok(holder.querySelector(".time-gap").nextElementSibling.matches(".bubble.user"));
});

// A participant's turn has no Apply row; the badge says its mode.
test("no Apply row under a participant's turn; the badge says the mode", () => {
  const turn = (id, mode) => [
    { role: "user", content: "q", turn_id: id, author: "p:p_0001abcd", author_name: "Sam", ...(mode ? { participant_mode: mode } : {}) },
    { role: "assistant", content: "done" },
  ];
  const review = historyHtml(turn("rev-1", "review"));
  assert.doesNotMatch(review, /data-apply-turn|review-apply/);
  assert.match(review, />Sam · read-only</);
  // A saved turn with no stamp is an older chi's read-only one (as Steer reads it).
  assert.match(historyHtml(turn("old-1", null)), />Sam · read-only</);
  const pair = historyHtml(turn("pair-1", "pair"));
  assert.doesNotMatch(pair, /review-apply/);
  assert.match(pair, />Sam · pair</);
  assert.match(pair, /data-participant-mode="pair"/);
  assert.match(pair, /title="A turn from Sam, a participant: it acted with this session's tools, its asks came to you"/);
});

test("a reloaded participant's block says so, as live stamps it; the owner's doesn't", () => {
  const turn = (author) => [
    { role: "user", content: "q", turn_id: "T1", ...(author ? { author } : {}) },
    { role: "assistant", content: "", parts: { tools: [{ name: "edit", params: 'path="a"', output: "[edit]\nok" }] } },
    { role: "assistant", content: "done" },
  ];
  assert.match(historyHtml(turn("p:p_0001abcd")), /<details class="turn-work done" data-end="completed" data-participant="1"/);
  assert.doesNotMatch(historyHtml(turn(null)), /data-participant/);
});
