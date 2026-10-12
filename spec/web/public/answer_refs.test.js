import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { answerRefsOf, applyFinalAnswer, pairAnswerRefs, setAnswerRefs } from "../../../lib/samagotchi/web/public/answer_refs.js";
import { normalize } from "../../../lib/samagotchi/web/public/format.js";
import { boundRef, refActions, refTarget } from "../../../lib/samagotchi/web/public/refs.js";
import { linkRefs } from "../../../lib/samagotchi/web/public/ref_scan.js";

const JIRA = "https://jira.test/browse/JIRA-1";
const BOARD = "https://jira.test/board/JIRA-1";
const issue = (match, extra = {}) => ({
  match, kind: "issue", target: { id: match },
  actions: [{ id: "open", label: "Open in Jira", url: `https://jira.test/browse/${match}` }], ...extra,
});

function bubble(html) {
  const el = document.createElement("div");
  el.className = "bubble output markdown";
  el.innerHTML = html;
  document.body.append(el);
  return el;
}

function paired(el, refs) {
  setAnswerRefs(el, refs);
  pairAnswerRefs(el);
  return [...el.querySelectorAll("[data-ref-kind]")];
}

const texts = (els) => els.map((el) => el.textContent);
const idOf = (el) => boundRef(el)?.target.id;

test("pass 1: a link whose href is one of the ref's action URLs, whatever its text", () => {
  const el = bubble(`<p>see <a href="${JIRA}">the ticket</a></p>`);
  const refs = paired(el, [{ ...issue("JIRA-1"), actions: [{ id: "open", label: "Open in Jira", url: JIRA }, { id: "board", label: "Board", url: BOARD }] }]);
  assert.equal(refs.length, 1);
  assert.equal(refs[0].tagName, "A");
  assert.equal(idOf(refs[0]), "JIRA-1");
  // The link's own target is labelled by the action with its URL; the other joins it.
  const target = refTarget(refs[0]);
  const actions = refActions(target, { editor: false });
  assert.deepEqual(actions.map((a) => a.label(target)), ["Open in Jira", "Board"]);
  el.remove();
});

test("pass 2: a link whose text is the match; pass 3: the match as a whole token in plain text", () => {
  const el = bubble('<p>see <a href="https://other.test/x">JIRA-2</a> and JIRA-1, not JIRA-12, xJIRA-1 or JIRA-1/a; JIRA-1.</p>');
  const refs = paired(el, [issue("JIRA-2"), issue("JIRA-1")]);
  assert.deepEqual(refs.map((r) => [r.tagName, r.textContent, idOf(r)]), [
    ["A", "JIRA-2", "JIRA-2"], ["SPAN", "JIRA-1", "JIRA-1"], ["SPAN", "JIRA-1", "JIRA-1"],
  ]);
  assert.equal(el.textContent, "see JIRA-2 and JIRA-1, not JIRA-12, xJIRA-1 or JIRA-1/a; JIRA-1.");
  el.remove();
});

test("pass 2: a link to a URL the ref doesn't name takes its actions, not its label as the title", () => {
  const el = bubble('<p>see <a href="https://other.test/x">JIRA-2</a></p>');
  const [link] = paired(el, [issue("JIRA-2", { label: "JIRA-2 Login fails" })]);
  assert.equal(link.tagName, "A");
  assert.equal(link.hasAttribute("title"), false);
  const target = refTarget(link);
  const actions = refActions(target, { editor: false });
  assert.deepEqual(actions.map((a) => [a.id, a.label(target)]), [["link", "Open link"], ["url:open", "Open in Jira"]]);
  el.remove();
});

test("pass 3: a match split by emphasis or across nodes isn't paired; pre, code (unless the match alone) and another ref are skipped", () => {
  const el = bubble('<p>JIRA-<em>1</em> and <code>x JIRA-1</code> and <code>JIRA-1</code></p><pre><code>JIRA-1</code></pre><p><span class="ref" data-ref-kind="file">JIRA-1</span></p>');
  const refs = paired(el, [issue("JIRA-1")]);
  assert.equal(refs.length, 2); // the old ref and the code alone
  const code = refs.find((r) => r.tagName === "SPAN" && r.querySelector("code"));
  assert.equal(code.textContent, "JIRA-1");
  assert.equal(idOf(code), "JIRA-1");
  assert.equal(el.querySelector("pre [data-ref-kind]"), null);
  assert.equal(boundRef(el.querySelector('[data-ref-kind="file"]')), null);
  el.remove();
});

test("pass order: one ref's text match doesn't take another ref's href link", () => {
  const el = bubble(`<p><a href="${JIRA}">ABC-3</a> then ABC-3</p>`);
  // ABC-3 comes first in the list; JIRA-1's href is the link's.
  const refs = paired(el, [issue("ABC-3"), { ...issue("JIRA-1"), actions: [{ id: "open", label: "Open", url: JIRA }] }]);
  assert.deepEqual(refs.map((r) => [r.tagName, idOf(r)]), [["A", "JIRA-1"], ["SPAN", "ABC-3"]]);
  el.remove();
});

test("every occurrence the winning pass finds, across text nodes; two refs in one text node both pair", () => {
  const el = bubble("<p>A-1 and B-2 then A-1</p><ul><li>A-1</li></ul>");
  const refs = paired(el, [issue("A-1"), issue("B-2")]);
  assert.deepEqual(refs.map((r) => [r.textContent, idOf(r)]), [["A-1", "A-1"], ["B-2", "B-2"], ["A-1", "A-1"], ["A-1", "A-1"]]);
  assert.equal(el.textContent, "A-1 and B-2 then A-1A-1");
  el.remove();
});

test("an overlapping hit of a later ref is dropped; a ref nothing pairs is dropped silently", () => {
  const el = bubble("<p>see foo bar here</p>");
  const refs = paired(el, [issue("foo bar"), issue("bar here"), issue("NOPE-1")]);
  assert.deepEqual(texts(refs), ["foo bar"]);
  assert.equal(el.textContent, "see foo bar here");
  el.remove();
});

test("a link the regex scanner adopted is rebound by the plugin's ref; its actions win", () => {
  const PR = "https://github.com/acme/app/pull/4/files#diff-1R11";
  const el = bubble(`<p>see <a href="${PR}"><code>lib/a.rb:11</code></a></p>`);
  linkRefs(el, new Set(["/p/lib/a.rb"]), "/p");
  const link = el.querySelector("a");
  assert.equal(link.dataset.refKind, "file");
  assert.equal(boundRef(link), null);
  paired(el, [{ match: "lib/a.rb:11", kind: "file", target: { path: "/p/lib/a.rb", line: 11 }, actions: [{ id: "pr", label: "PR diff (#4)", url: PR }] }]);
  assert.equal(boundRef(link).actions[0].label, "PR diff (#4)");
  const target = refTarget(link);
  assert.equal(refActions(target, { editor: false })[0].label(target), "PR diff (#4)");
  el.remove();
});

test("pairAnswerRefs runs once per setAnswerRefs; setAnswerRefs again pairs again (a re-rendered bubble)", () => {
  const el = bubble("<p>A-1</p>");
  setAnswerRefs(el, [issue("A-1")]);
  pairAnswerRefs(el);
  const first = el.querySelector("[data-ref-kind]");
  pairAnswerRefs(el);
  assert.equal(el.querySelectorAll("[data-ref-kind]").length, 1);
  assert.equal(el.querySelector("[data-ref-kind]"), first);
  el.innerHTML = "<p>A-1 B-2</p>";
  setAnswerRefs(el, [issue("A-1"), issue("B-2")]);
  pairAnswerRefs(el);
  assert.deepEqual(texts([...el.querySelectorAll("[data-ref-kind]")]), ["A-1", "B-2"]);
  el.remove();
});

test("setAnswerRefs keeps usable refs only and clears on none; junk doesn't throw", () => {
  const el = bubble("<p>A-1</p>");
  setAnswerRefs(el, [42, null, { kind: null }, { kind: "issue" }, { kind: "issue", match: "  " }, issue("A-1")]);
  assert.deepEqual(answerRefsOf(el).map((r) => r.match), ["A-1"]);
  setAnswerRefs(el, "nope");
  assert.equal(answerRefsOf(el), null);
  setAnswerRefs(el, [issue("A-1")]);
  setAnswerRefs(el, []);
  assert.equal(answerRefsOf(el), null);
  setAnswerRefs(null, [issue("A-1")]);
  pairAnswerRefs(null);
  pairAnswerRefs(el);
  // A kind the server's Ref refuses is dropped (it doesn't take the text from a good one).
  paired(el, [{ match: "A-1", kind: "Bad Kind", target: {} }, { match: "A-1", kind: "issue", target: { id: "x" }, actions: "junk" }]);
  const refs = [...el.querySelectorAll("[data-ref-kind]")];
  assert.deepEqual(refs.map((r) => r.dataset.refKind), ["issue"]);
  assert.deepEqual(boundRef(refs[0]).actions, []);
  el.remove();
});

test("an XSS match or label stays text: no element but the ref's span", () => {
  const evil = '<img src=x onerror="globalThis.__pwned=1">';
  const el = document.createElement("div");
  el.className = "bubble output";
  el.textContent = `see ${evil} and "><script>x</script> end`;
  document.body.append(el);
  const refs = paired(el, [
    { match: evil, kind: "issue", target: { id: "1" }, label: '"><script>alert(1)</script>' },
    { match: '"><script>x</script>', kind: "issue", target: { id: "2" }, label: evil },
  ]);
  assert.equal(refs.length, 2);
  assert.equal(el.querySelectorAll("img, script").length, 0);
  assert.deepEqual([...el.querySelectorAll("*")].map((n) => n.tagName), ["SPAN", "SPAN"]);
  assert.equal(refs[0].textContent, evil);
  assert.equal(refs[0].getAttribute("title"), '"><script>alert(1)</script>');
  assert.equal(refs[1].getAttribute("title"), evil);
  assert.equal(globalThis.__pwned, undefined);
  el.remove();
});

test("label: the hover title when it differs from the text, never over the element's own title", () => {
  const el = bubble(`<p>A-1 and B-2 <a href="${JIRA}" title="Mine">ticket</a></p>`);
  paired(el, [
    issue("A-1", { label: "A-1 Login fails" }),
    issue("B-2", { label: "B-2" }),
    { ...issue("JIRA-1", { label: "JIRA-1 Something" }), actions: [{ id: "open", label: "Open", url: JIRA }] },
  ]);
  const [a, b] = el.querySelectorAll("span[data-ref-kind]");
  assert.equal(a.getAttribute("title"), "A-1 Login fails");
  assert.equal(b.hasAttribute("title"), false);
  assert.equal(el.querySelector("a").getAttribute("title"), "Mine");
  el.remove();
});

test("applyFinalAnswer: the last answer's html replaces its streamed bubble's, which takes its refs; a read without refs clears them", () => {
  const old = bubble("Earlier.");
  const live = bubble("See JIRA-1.");
  const refs = [issue("JIRA-1")];
  const messages = [
    { role: "assistant", content: "Earlier.", html: "<p>Earlier.</p>" },
    { role: "assistant", content: "See JIRA-1.", html: "<p>See <strong>JIRA-1</strong>.</p>", display_refs: refs },
    { role: "assistant", content: "" },
  ];
  assert.equal(applyFinalAnswer(messages, [old, live], normalize), live);
  assert.equal(live.innerHTML, "<p>See <strong>JIRA-1</strong>.</p>");
  assert.ok(live.classList.contains("markdown"));
  assert.equal(live.getAttribute("data-copy-source"), "See JIRA-1.");
  assert.deepEqual(answerRefsOf(live), refs);
  assert.equal(answerRefsOf(old), null);
  applyFinalAnswer(messages.map(({ display_refs: _drop, ...m }) => m), [old, live], normalize);
  assert.equal(answerRefsOf(live), null);
  old.remove();
  live.remove();
});

test("applyFinalAnswer without html (web.markdown off): the bubble keeps its text and still takes the refs", () => {
  const live = document.createElement("div");
  live.className = "bubble output";
  live.textContent = "See <b>JIRA-1</b>.";
  document.body.append(live);
  const refs = [issue("JIRA-1")];
  assert.equal(applyFinalAnswer([{ role: "assistant", content: "See <b>JIRA-1</b>.", display_refs: refs }], [live], normalize), live);
  assert.equal(live.textContent, "See <b>JIRA-1</b>.");
  assert.equal(live.querySelector("b"), null);
  assert.equal(live.classList.contains("markdown"), false);
  assert.deepEqual(answerRefsOf(live), refs);
  pairAnswerRefs(live);
  assert.equal(live.querySelector('span[data-ref-kind="issue"]').textContent, "JIRA-1");
  // No answer, no bubble: nothing happens.
  assert.equal(applyFinalAnswer([{ role: "assistant", content: "other" }], [live], normalize), null);
  assert.equal(applyFinalAnswer(null, [live], normalize), null);
  live.remove();
});

test("without html (web.markdown off), a path:line the scan wrapped before the refs came is bound to the plugin's file ref", () => {
  const live = document.createElement("div");
  live.className = "bubble output";
  live.textContent = "see a.rb:3";
  document.body.append(live);
  // The turn-end read: no refs yet, the scan wraps the touched file's ref.
  applyFinalAnswer([{ role: "assistant", content: "see a.rb:3" }], [live], normalize);
  pairAnswerRefs(live);
  linkRefs(live, new Set(["/p/a.rb"]), "/p");
  const span = live.querySelector('span[data-ref-kind="file"]');
  assert.equal(span.textContent, "a.rb:3");
  assert.equal(boundRef(span), null);
  // The answer_display re-read: the refs, the same bubble (no re-render).
  const PR = "https://github.com/acme/app/pull/4/files#diff-1R3";
  applyFinalAnswer([{ role: "assistant", content: "see a.rb:3", display_refs: [
    { match: "a.rb:3", kind: "file", target: { path: "/p/a.rb", line: 3 }, actions: [{ id: "pr", label: "PR diff", url: PR }] },
  ] }], [live], normalize);
  pairAnswerRefs(live);
  assert.equal(live.querySelectorAll("[data-ref-kind]").length, 1);
  assert.equal(live.querySelector("[data-ref-kind]"), span);
  assert.deepEqual(boundRef(span).actions, [{ id: "pr", label: "PR diff", url: PR }]);
  assert.equal(span.dataset.refLine, "3");
  live.remove();
});
