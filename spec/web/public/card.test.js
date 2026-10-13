import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { cardBodyTemplate, cardClass, cardPlace, cardTemplate, drawCard, isCard, isNoticeCard, leavesBlock, noticeCardLine, noticeTemplate, NOTICE_CHARS, refreshCardBody, shownElsewhere, splitSnapshotCards, turnNoticePlace } from "../../../lib/samagotchi/web/public/card.js";

// The templates' markup as the page gets it.
const cardInnerHtml = (c) => markupOf(cardTemplate(c));
const cardBodyHtml = (c) => markupOf(cardBodyTemplate(c));
const noticeInnerHtml = (c) => markupOf(noticeTemplate(c));

const card = {
  type: "card", id: "c1", source: "sample-plugin", title: "Hello <you>", body: "hi *there*", level: "info",
  actions: [{ label: "Again", command: "/hello again" }, { label: "", command: '/x "y"' }],
};

test("cardTemplate: the head (title, source), the body and one button per action, all escaped", () => {
  assert.equal(cardInnerHtml(card),
    '<div class="card-head"><span class="card-title">Hello &lt;you&gt;</span><span class="card-source">sample-plugin</span></div>' +
    '<div class="card-body"><pre>hi *there*</pre></div>' +
    '<div class="card-actions">' +
    '<button type="button" class="card-action ghost" data-command="/hello again" title="/hello again">Again</button>' +
    '<button type="button" class="card-action ghost" data-command="/x &quot;y&quot;" title="/x &quot;y&quot;">/x "y"</button>' +
    '</div><div class="card-error hidden"></div>');
});

test("cardTemplate: no body and no actions leave out their parts", () => {
  assert.equal(cardInnerHtml({ title: "T", body: " ", actions: [{ label: "no command" }] }),
    '<div class="card-head"><span class="card-title">T</span></div><div class="card-error hidden"></div>');
});

test("cardBodyTemplate: the server's body_html (rendered markdown), else the text escaped in a <pre>", () => {
  assert.equal(cardBodyHtml({ ...card, body_html: "<p>hi <em>there</em></p>" }), "<p>hi <em>there</em></p>");
  assert.equal(cardBodyHtml({ body: "a < b" }), "<pre>a &lt; b</pre>");
  assert.equal(cardBodyHtml({ body: "x", body_html: "" }), "");
  assert.equal(cardBodyHtml({}), "");
});

test("cardClass: a warn card wears the warning colour", () => {
  assert.equal(cardClass(card), "bubble plugin-card");
  assert.equal(cardClass({ ...card, level: "warn" }), "bubble plugin-card warn");
});

const nudged = { type: "card", id: "check-in-1", source: "check-in", title: "check-in", body: "Nudged the model at 105 tool calls.", level: "info" };

test("isNoticeCard: an info card with nothing to click and one short line is a notice", () => {
  assert.equal(isNoticeCard(nudged), true);
  assert.equal(isNoticeCard({ ...nudged, body: "" }), true);
  assert.equal(isNoticeCard({ ...nudged, actions: [{ label: "x" }] }), true);
  assert.equal(isNoticeCard({ ...nudged, level: "warn" }), false);
  assert.equal(isNoticeCard({ ...nudged, actions: [{ label: "Nudge", command: "/checkin nudge" }] }), false);
  assert.equal(isNoticeCard({ ...nudged, body: "line one\nline two" }), false);
  assert.equal(isNoticeCard({ ...nudged, body: "x".repeat(NOTICE_CHARS + 1) }), false);
  assert.equal(isNoticeCard(null), false);
});

test("cardClass: a notice is marked for its one-line row", () => {
  assert.equal(cardClass(nudged), "bubble plugin-card notice");
  assert.equal(cardClass(card), "bubble plugin-card");
});

test("noticeCardLine / noticeTemplate: 'title: body' as the summary, the source when it differs, escaped", () => {
  assert.equal(noticeCardLine(nudged), "check-in: Nudged the model at 105 tool calls.");
  assert.equal(noticeCardLine({ title: "T", body: " " }), "T");
  assert.equal(noticeInnerHtml(nudged), "<summary>check-in: Nudged the model at 105 tool calls.</summary>");
  assert.equal(noticeInnerHtml({ title: "kept as <a>", body: "b", source: "btw" }),
    '<summary>kept as &lt;a&gt;: b</summary><div class="notice-from">from <span class="card-source">btw</span></div>');
});

test("cardPlace: above the first turn after the card (turns_since from the end), else the end", () => {
  const users = ["u1", "u2", "u3"];
  assert.equal(cardPlace(users, { turns_since: 0 }), null);
  assert.equal(cardPlace(users, { turns_since: 1 }), "u3");
  assert.equal(cardPlace(users, { turns_since: 3 }), "u1");
  // From before this page's turns (an older worker's count): the end.
  assert.equal(cardPlace(users, { turns_since: 9 }), null);
});

test("splitSnapshotCards: the history's cards and notices, the running turn's cards, and the ones during it", () => {
  const cards = [{ id: "a", current: false }, { type: "hook_notice", current: false }, { type: "card", id: "b", current: true },
    { id: "btw", current: false, during: true },
    // The running turn's own rows come with its parts, never as cards.
    { type: "hook_notice", in_turn: true, current: true }, { type: "empty_answer_retry", in_turn: true, current: true }];
  assert.deepEqual(splitSnapshotCards(cards), { placed: [cards[0], cards[1]], current: [cards[2]], during: [cards[3]] });
  assert.deepEqual(splitSnapshotCards(undefined), { placed: [], current: [], during: [] });
});

test("shownElsewhere: a notice marked fallback_for a capability the page has; unmarked or without it, shown", () => {
  const marked = { type: "hook_notice", text: "sources: JIRA-1", fallback_for: "display" };
  assert.equal(shownElsewhere(marked, { display: true }), true);
  assert.equal(shownElsewhere(marked, { display: false }), false);
  assert.equal(shownElsewhere(marked, {}), false);
  assert.equal(shownElsewhere(marked, undefined), false);
  assert.equal(shownElsewhere({ type: "hook_notice", text: "plain" }, { display: true }), false);
  assert.equal(shownElsewhere({ ...marked, fallback_for: "terminal" }, { display: true }), false);
  // An editor notice: left out only for a viewer that can open refs.
  assert.equal(shownElsewhere({ ...marked, fallback_for: "editor" }, { display: true, editor: true }), true);
  assert.equal(shownElsewhere({ ...marked, fallback_for: "editor" }, { display: true, editor: false }), false);
  assert.equal(shownElsewhere(null, { display: true }), false);
});

test("splitSnapshotCards: a notice the page shows elsewhere is left out, between turns and of a finished turn", () => {
  const between = { type: "hook_notice", text: "sources: a", fallback_for: "display", in_turn: false, current: false };
  const ofTurn = { type: "hook_notice", text: "sources: b", fallback_for: "display", in_turn: true, current: false };
  const plain = { type: "hook_notice", text: "plain", in_turn: false, current: false };
  const cards = [between, ofTurn, plain];
  assert.deepEqual(splitSnapshotCards(cards, { display: true }).placed, [plain]);
  assert.deepEqual(splitSnapshotCards(cards, { display: false }).placed, cards);
  assert.deepEqual(splitSnapshotCards(cards).placed, cards);
});

test("isCard: a card entry (typed or not), not a notice or a row", () => {
  assert.equal(isCard({ type: "card" }), true);
  assert.equal(isCard({ id: "x" }), true);
  assert.equal(isCard({ type: "hook_notice" }), false);
  assert.equal(isCard({ type: "empty_answer_retry" }), false);
});

test("leavesBlock: a warn card always leaves the collapsed block, any card of a turn that did not complete does", () => {
  assert.equal(leavesBlock({ warn: false, kind: "completed" }), false);
  assert.equal(leavesBlock({ warn: true, kind: "completed" }), true);
  for (const kind of ["canceled", "failed", "gone"]) {
    assert.equal(leavesBlock({ warn: false, kind }), true, kind);
    assert.equal(leavesBlock({ warn: true, kind }), true, kind);
  }
});

test("turnNoticePlace: a turn notice's step (0-based) and the row it came before", () => {
  assert.deepEqual(turnNoticePlace({ type: "hook_notice", in_turn: true, iteration: 2, calls: 0 }), { step: 1, rowKey: "2:1" });
  assert.deepEqual(turnNoticePlace({ type: "hook_notice", in_turn: true, iteration: 1, calls: 2 }), { step: 0, rowKey: "1:3" });
  assert.deepEqual(turnNoticePlace({ type: "hook_notice", in_turn: true, iteration: 3 }), { step: 2, rowKey: "3:1" });
  // Before the first generation (a before_turn hook's): the first step, above its first row.
  assert.deepEqual(turnNoticePlace({ type: "hook_notice", in_turn: true, calls: 0 }), { step: 0, rowKey: "1:1" });
  // A bad iteration, or not a turn's notice: before the turn's answer.
  assert.equal(turnNoticePlace({ type: "hook_notice", in_turn: true, iteration: 0 }), null);
  assert.equal(turnNoticePlace({ type: "hook_notice", in_turn: false, iteration: 1, calls: 0 }), null);
  assert.equal(turnNoticePlace(null), null);
});

test("turnNoticePlace: a turn-end ✂ row names its turn's last step; a reload with no such step puts it before the answer", () => {
  // CardStore keeps the last generation's iteration and no calls: the
  // answer's own step, which a reloaded turn draws only with thinking or
  // tools (else app.js's placeTurnNotice falls back to a bubble before the
  // answer, as promote leaves it live).
  assert.deepEqual(turnNoticePlace({ type: "llm_context_edited", in_turn: true, iteration: 3, calls: 0 }), { step: 2, rowKey: "3:1" });
});

// A card element drawn as app.js does (upsertCard): a new one, then the
// same card's updates on it.
const drawn = (c) => drawCard(document.createElement(isNoticeCard(c) ? "details" : "div"), c);

test("drawCard: the same card again from the stream keeps its rendered body (the same nodes) and its text-only update shows it", () => {
  const el = drawn({ ...card, body_html: "<p>hi <em>there</em></p>" });
  const p = el.querySelector(".card-body p");
  // The stream's update: the same body as text, no html; a new title.
  assert.equal(drawCard(el, { ...card, title: "Hello again" }), el);
  assert.ok(el.querySelector(".card-body p") === p);
  assert.equal(el.querySelector(".card-title").textContent, "Hello again");
  // Another body: drawn as text until the re-read brings its html.
  drawCard(el, { ...card, body: "bye" });
  assert.equal(el.querySelector(".card-body").innerHTML.replace(/<!--[^]*?-->/g, ""), "<pre>bye</pre>");
  refreshCardBody(el, { ...card, body: "bye", body_html: "<p>bye</p>" });
  assert.equal(markupOf(cardTemplate({ ...card, body: "bye", body_html: "<p>bye</p>" })), el.innerHTML.replace(/<!--[^]*?-->/g, ""));
  // A re-read of a body the card no longer shows changes nothing.
  refreshCardBody(el, { ...card, body: "old", body_html: "<p>old</p>" });
  assert.match(el.querySelector(".card-body").innerHTML, /<p>bye<\/p>/);
});

test("drawCard: an opened notice stays open across an update; one that turns into a card is drawn on a new element in its place", () => {
  const nudged = { id: "n1", title: "check-in", body: "Nudged the model.", source: "check-in" };
  const holder = document.createElement("div");
  const el = drawn(nudged);
  holder.append(el);
  el.open = true;
  assert.equal(drawCard(el, { ...nudged, body: "Nudged the model twice." }), el);
  assert.equal(el.open, true);
  assert.equal(el.querySelector("summary").textContent, "check-in: Nudged the model twice.");
  const asks = drawCard(el, { ...nudged, actions: [{ label: "Stop", command: "/stop" }] });
  assert.ok(asks !== el);
  assert.equal(asks.tagName, "DIV");
  assert.ok(holder.firstElementChild === asks);
  assert.equal(asks.className, "bubble plugin-card");
  assert.equal(asks.dataset.cardId, "n1");
});

test("drawCard: a failed action's line goes when the card is drawn again; a warn card in a turn says so", () => {
  const el = drawn({ ...card, level: "warn", in_turn: true });
  assert.equal(el.className, "bubble plugin-card warn");
  assert.equal(el.dataset.inTurn, "1");
  const error = el.querySelector(".card-error");
  error.textContent = "boom";
  error.classList.remove("hidden");
  drawCard(el, card);
  assert.equal(el.querySelector(".card-error").textContent, "");
  assert.ok(el.querySelector(".card-error").classList.contains("hidden"));
  assert.equal(el.dataset.inTurn, undefined);
});
