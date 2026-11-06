// The owner page's claim links (owner_claim.js) over a drawn history and
// stand-in hooks: Copy link's two links, where it offers none, and a claim
// link opened on this page (no e2e opens #/s/<id>?t= on the owner's page).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { CLAIM_ROOTS, createOwnerClaim } from "../../../lib/samagotchi/web/public/owner_claim.js";
import { ownerClaimHash, participantClaimLink } from "../../../lib/samagotchi/web/public/claim_link.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

const ID = "d4c5c3af-a814-48dd-a59c-fffa4bc0b094";
const TURN = "0a1b2c3d-1111-2222-3333-444455556666";

function harness({ target = null, hash = `#/s/${ID}`, allView = false, copies = true } = {}) {
  const historyEl = document.createElement("div");
  historyEl.innerHTML = `<div class="bubble user" data-turn-id="${TURN}"><div class="user-message">Count the files</div></div>
    <div class="bubble output">The count is wrong in a.rb.</div>
    <div data-stack-view="1"><div class="bubble output">An older version</div></div>`;
  document.body.appendChild(historyEl);
  const store = createSessionStore({ initial: { dir: "/Users/sam/app" } });
  store.update({ selected: ID });
  const toasts = [];
  const replaced = [];
  const copied = [];
  const win = {
    location: { origin: "http://127.0.0.1:4567", pathname: "/", search: "?dir=x", hash },
    history: { replaceState: (_s, _t, url) => replaced.push(url) },
  };
  const claim = createOwnerClaim({
    historyEl, store, claimTarget: () => target,
    toast: (text, action = null, options = {}) => toasts.push({ text, options }),
    copyText: async (text) => { copied.push(text); return copies; },
    allViewOpen: () => allView, home: "/Users/sam", win,
  });
  const answer = historyEl.querySelector(".bubble.output");
  const rangeOf = (el, from, to) => {
    const range = document.createRange();
    range.setStart(el.firstChild, from);
    range.setEnd(el.firstChild, to);
    return range;
  };
  return { claim, historyEl, store, toasts, replaced, copied, answer, rangeOf };
}

test("with no person invited, Copy link is this page's own claim hash", () => {
  const h = harness();
  const link = h.claim.linkFor({ kind: "answer", root: h.answer }, h.rangeOf(h.answer, 10, 18));
  const hash = ownerClaimHash(ID, { turnId: TURN, q: "is wrong", p: "The count " });
  assert.equal(link.url, `http://127.0.0.1:4567/?dir=x${hash}`);
  assert.match(link.title, /no person is invited/);
  h.historyEl.remove();
});

test("with a person active, Copy link is the participant page's link, named for them", () => {
  const target = { base: "http://192.168.1.2:4567/", names: ["Alex", "Sam"] };
  const h = harness({ target });
  const link = h.claim.linkFor({ kind: "answer", root: h.answer }, h.rangeOf(h.answer, 10, 18));
  assert.equal(link.url, participantClaimLink(target.base, ID, { turnId: TURN, q: "is wrong", p: "The count " }));
  assert.match(link.title, /Alex's or Sam's browser/);
  h.historyEl.remove();
});

test("no link in a Revise stack's switched copy, outside the history, for another kind, or with no session", () => {
  const h = harness();
  const copy = h.historyEl.querySelector("[data-stack-view] .bubble.output");
  assert.equal(h.claim.linkFor({ kind: "answer", root: copy }, h.rangeOf(copy, 0, 5)), null);
  const outside = document.createElement("div");
  outside.textContent = "elsewhere";
  assert.equal(h.claim.linkFor({ kind: "answer", root: outside }, h.rangeOf(outside, 0, 4)), null);
  assert.equal(h.claim.linkFor({ kind: "thinking", root: h.answer }, h.rangeOf(h.answer, 10, 18)), null);
  h.store.update({ selected: null });
  assert.equal(h.claim.linkFor({ kind: "answer", root: h.answer }, h.rangeOf(h.answer, 10, 18)), null);
  h.historyEl.remove();
});

test("Copy link's toast: copied, or the link itself, sticky", async () => {
  const h = harness();
  await h.claim.copyLink({ url: "http://x/#a" });
  assert.deepEqual(h.toasts.at(-1), { text: "Link copied", options: {} });
  const refused = harness({ copies: false });
  await refused.claim.copyLink({ url: "http://x/#a" });
  assert.deepEqual(refused.toasts.at(-1), { text: "Couldn't copy: http://x/#a", options: { sticky: true } });
  h.historyEl.remove();
  refused.historyEl.remove();
});

test("a pending claim shows once its session is open: the quote marked, the hash the session's again", () => {
  const h = harness({ hash: `#/s/${ID}?t=0a1b2c3d&q=is+wrong` });
  h.claim.pending({ sessionId: ID, turn: "0a1b2c3d", q: "is wrong", p: "The count " });
  h.claim.showPending();
  assert.ok(h.answer.classList.contains("claim-hit"));
  assert.deepEqual(h.replaced, [`/?dir=x#/s/${ID}`]);
  assert.deepEqual(h.toasts, []);
  // Shown once: a second call does nothing.
  h.answer.classList.remove("claim-hit");
  h.claim.showPending();
  assert.equal(h.answer.classList.contains("claim-hit"), false);
  h.historyEl.remove();
});

test("a pending claim for another session waits; one not found goes to the top with a toast", () => {
  const h = harness();
  h.claim.pending({ sessionId: "another", turn: "0a1b2c3d", q: "is wrong" });
  h.claim.showPending();
  assert.deepEqual(h.toasts, []);
  h.historyEl.scrollTop = 50;
  h.claim.pending({ sessionId: ID, turn: "99999999", q: "nowhere at all" });
  h.claim.showPending();
  assert.equal(h.historyEl.scrollTop, 0);
  assert.deepEqual(h.toasts, [{ text: "The linked turn isn't in this session.", options: {} }]);
  // The hash already the session's: left alone.
  assert.deepEqual(h.replaced, []);
  h.historyEl.remove();
});

test("opts: the session's folder and home, as the participant page shows text; the roots are the owner's", () => {
  const h = harness();
  assert.deepEqual(h.claim.opts(), { home: "/Users/sam", cwd: "/Users/sam/app" });
  assert.equal(CLAIM_ROOTS, ".bubble.output, .bubble.user .user-message, .gen-text");
  h.historyEl.remove();
});
