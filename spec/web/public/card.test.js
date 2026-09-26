import test from "node:test";
import assert from "node:assert/strict";
import { cardBodyHtml, cardClass, cardInnerHtml, cardPlace, splitSnapshotCards } from "../../../lib/samagotchi/web/public/card.js";

const card = {
  type: "card", id: "c1", source: "sample-plugin", title: "Hello <you>", body: "hi *there*", level: "info",
  actions: [{ label: "Again", command: "/hello again" }, { label: "", command: '/x "y"' }],
};

test("cardInnerHtml: the head (title, source), the body and one button per action, all escaped", () => {
  assert.equal(cardInnerHtml(card),
    '<div class="card-head"><span class="card-title">Hello &lt;you&gt;</span><span class="card-source">sample-plugin</span></div>' +
    '<div class="card-body"><pre>hi *there*</pre></div>' +
    '<div class="card-actions">' +
    '<button type="button" class="card-action ghost" data-command="/hello again" title="/hello again">Again</button>' +
    '<button type="button" class="card-action ghost" data-command="/x &quot;y&quot;" title="/x &quot;y&quot;">/x &quot;y&quot;</button>' +
    '</div><div class="card-error hidden"></div>');
});

test("cardInnerHtml: no body and no actions leave out their parts", () => {
  assert.equal(cardInnerHtml({ title: "T", body: " ", actions: [{ label: "no command" }] }),
    '<div class="card-head"><span class="card-title">T</span></div><div class="card-error hidden"></div>');
});

test("cardBodyHtml: the server's body_html (rendered markdown), else the text escaped in a <pre>", () => {
  assert.equal(cardBodyHtml({ ...card, body_html: "<p>hi <em>there</em></p>" }), "<p>hi <em>there</em></p>");
  assert.equal(cardBodyHtml({ body: "a < b" }), "<pre>a &lt; b</pre>");
  assert.equal(cardBodyHtml({ body: "x", body_html: "" }), "");
  assert.equal(cardBodyHtml({}), "");
});

test("cardClass: a warn card wears the warning colour", () => {
  assert.equal(cardClass(card), "bubble plugin-card");
  assert.equal(cardClass({ ...card, level: "warn" }), "bubble plugin-card warn");
});

test("cardPlace: above the first turn after the card (turns_since from the end), else the end", () => {
  const users = ["u1", "u2", "u3"];
  assert.equal(cardPlace(users, { turns_since: 0 }), null);
  assert.equal(cardPlace(users, { turns_since: 1 }), "u3");
  assert.equal(cardPlace(users, { turns_since: 3 }), "u1");
  // From before this page's turns (an older worker's count): the end.
  assert.equal(cardPlace(users, { turns_since: 9 }), null);
});

test("splitSnapshotCards: the history's cards and notices, the running turn's, and the ones during it", () => {
  const cards = [{ id: "a", current: false }, { type: "hook_notice", current: false }, { id: "b", current: true },
    { id: "btw", current: false, during: true }];
  assert.deepEqual(splitSnapshotCards(cards), { placed: [cards[0], cards[1]], current: [cards[2]], during: [cards[3]] });
  assert.deepEqual(splitSnapshotCards(undefined), { placed: [], current: [], during: [] });
});
