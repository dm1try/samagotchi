import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  HIGHLIGHT, HIT_CLASS, PREFIX_MAX, QUOTE_MAX, claimFromHash, claimParams, claimQuote, clearClaim, findClaim, normalizeClaim,
  normalizeWithMap, ownerClaimHash, participantClaimLink, selectionClaim, showClaim, turnIdOf, turnRoots,
} from "../../../lib/samagotchi/web/public/claim_link.js";

const ID = "d4c5c3af-a814-48dd-a59c-fffa4bc0b094";
const TURN = "0a1b2c3d-1111-2222-3333-444455556666";
const OWNER = { home: "/Users/sam", cwd: "/Users/sam/projects/app" };

test("normalized: whitespace collapsed and trimmed", () => {
  assert.equal(normalizeClaim("  the\n\n  answer\tis  42 "), "the answer is 42");
  assert.equal(normalizeClaim(null), "");
});

test("normalized on the owner's page as the participant page shows it: the folder relative, home ~", () => {
  assert.equal(normalizeClaim("see /Users/sam/projects/app/lib/a.rb and /Users/sam/projects/app", OWNER), "see lib/a.rb and .");
  assert.equal(normalizeClaim("in /Users/sam/.config/x", OWNER), "in ~/.config/x");
  // Another user whose name starts the same isn't home.
  assert.equal(normalizeClaim("/Users/samuel/x", OWNER), "/Users/samuel/x");
});

test("the map points each normalized character back at the raw text", () => {
  const raw = "a  /Users/sam/x";
  const { text, starts, ends } = normalizeWithMap(raw, OWNER);
  assert.equal(text, "a ~/x");
  // The collapsed space covers both blanks; "~" the whole home.
  assert.deepEqual([starts[1], ends[1]], [1, 3]);
  assert.deepEqual([starts[2], ends[2]], [3, 13]);
  assert.equal(raw.slice(starts[3], ends[4]), "/x");
});

test("a selection's quote and prefix: normalized, the quote clipped, the prefix its last characters", () => {
  assert.deepEqual(claimQuote(" is  wrong ", "The count "), { q: "is wrong", p: "The count " });
  assert.deepEqual(claimQuote("x", ""), { q: "x", p: "" });
  assert.deepEqual(claimQuote("  \n", "before"), { q: "", p: "" });
  const long = claimQuote("q".repeat(500), "p".repeat(100));
  assert.equal(long.q.length, QUOTE_MAX);
  assert.equal(long.p.length, PREFIX_MAX);
  // Never half an emoji.
  assert.equal(claimQuote("😀".repeat(300)).q, "😀".repeat(QUOTE_MAX));
});

test("the link's parts: the turn's first 8 characters, the quote, its prefix; URL-safe", () => {
  assert.equal(claimParams({ turnId: TURN, q: "a & b #1", p: "x " }), "t=0a1b2c3d&q=a+%26+b+%231&p=x+");
  assert.equal(claimParams({ turnId: TURN }), "t=0a1b2c3d");
  assert.equal(claimParams({ turnId: TURN, p: "x" }), "t=0a1b2c3d");
});

test("the participant link and the owner's hash round-trip through claimFromHash", () => {
  const claim = { turnId: TURN, q: "a = b?", p: "so " };
  const link = participantClaimLink("http://192.168.1.5:4567", ID, claim);
  assert.equal(link, `http://192.168.1.5:4567/#s=${ID}&t=0a1b2c3d&q=a+%3D+b%3F&p=so+`);
  assert.equal(participantClaimLink("https://chi.example/#code=x", ID, {}), `https://chi.example/#s=${ID}`);
  const expected = { sessionId: ID, turn: "0a1b2c3d", q: "a = b?", p: "so " };
  assert.deepEqual(claimFromHash(new URL(link).hash), expected);
  assert.equal(ownerClaimHash(ID, claim), `#/s/${ID}?t=0a1b2c3d&q=a+%3D+b%3F&p=so+`);
  assert.deepEqual(claimFromHash(ownerClaimHash(ID, claim)), expected);
});

test("hashes that name no turn are no claim", () => {
  for (const h of ["", "#", `#/s/${ID}`, `#s=${ID}`, `#code=abc&s=${ID}`, "#/sessions", `#/s/${ID}?q=x`, `#s=${ID}&t=zz`, "#t=0a1b2c3d", "#/s/%E0%A4%A?t=0a"]) {
    assert.equal(claimFromHash(h), null, h);
  }
});

test("found: the prefix and the quote first, then the quote alone; raw offsets", () => {
  const texts = ["The count is wrong here.", "No: the count is wrong there."];
  assert.deepEqual(findClaim(texts, { q: "is wrong", p: "the count " }), { at: 1, start: 14, end: 22 });
  assert.deepEqual(findClaim(texts, { q: "is wrong", p: "nothing like it " }), { at: 0, start: 10, end: 18 });
  assert.equal(findClaim(texts, { q: "absent" }), null);
  assert.equal(findClaim(texts, { q: "" }), null);
  // The owner's text, read as the participant's.
  const at = findClaim(["edit /Users/sam/projects/app/lib/a.rb  now"], { q: "lib/a.rb now" }, OWNER);
  assert.deepEqual(at, { at: 0, start: 29, end: 42 });
});

// A participant thread: two turns, each an opening comment and a reply.
function thread() {
  const div = document.createElement("div");
  div.innerHTML = `
    <div class="p-msg user" data-turn-id="${TURN}"><div class="p-bubble">Check the count</div></div>
    <div class="p-msg reply"><details class="p-tools"><summary>read 2 files</summary></details><div class="p-bubble"><p>The count <b>is wrong</b> in a.rb.</p></div></div>
    <div class="p-msg user" data-turn-id="ffff0000-0000-0000-0000-000000000000"><div class="p-bubble">And b?</div></div>
    <div class="p-msg reply"><div class="p-bubble">The count is wrong in b.rb too.</div></div>`;
  document.body.replaceChildren(div);
  return div;
}

test("a turn's roots: its opening's and its replies', up to the next turn", () => {
  const div = thread();
  const turn = turnRoots(div, "0a1b2c3d", ".p-bubble");
  assert.equal(turn.anchor.dataset.turnId, TURN);
  assert.deepEqual(turn.roots.map((r) => r.textContent), ["Check the count", "The count is wrong in a.rb."]);
  assert.deepEqual(turnRoots(div, "ffff", ".p-bubble").roots.map((r) => r.textContent), ["And b?", "The count is wrong in b.rb too."]);
  assert.equal(turnRoots(div, "99999999", ".p-bubble"), null);
  assert.equal(turnRoots(div, "", ".p-bubble"), null);
});

test("the turn a node is in: the last opening at or before it", () => {
  const div = thread();
  const replies = div.querySelectorAll(".p-msg.reply .p-bubble");
  assert.equal(turnIdOf(div, replies[0].firstChild), TURN);
  assert.equal(turnIdOf(div, replies[1].firstChild), "ffff0000-0000-0000-0000-000000000000");
  assert.equal(turnIdOf(div, div.querySelector(".p-msg.user .p-bubble").firstChild), TURN);
  const before = document.createElement("p");
  div.prepend(before);
  assert.equal(turnIdOf(div, before), null);
});

test("a selection's claim reads its bubble's text before it", () => {
  const div = thread();
  const bold = div.querySelector("b");
  const range = document.createRange();
  range.selectNodeContents(bold);
  assert.deepEqual(selectionClaim(bold.closest(".p-bubble"), range), { q: "is wrong", p: "The count " });
});

// A window with the CSS Highlight API: the ranges it was given.
function highlightWin() {
  const set = new Map();
  class Highlight { constructor(...ranges) { this.ranges = ranges; } }
  return { CSS: { highlights: set }, Highlight, set };
}

test("shown: the quote's bubble marked and opened, the quote highlighted", () => {
  const div = thread();
  const win = highlightWin();
  div.querySelector("details").open = false;
  const bubble = div.querySelectorAll(".p-bubble")[1];
  assert.equal(showClaim(div, { turn: "0a1b2c3d", q: "is wrong in a.rb.", p: "The count " }, { roots: ".p-bubble", win }), "quote");
  assert.equal(div.querySelectorAll(`.${HIT_CLASS}`).length, 1);
  assert.ok(bubble.classList.contains(HIT_CLASS));
  assert.equal(win.set.get(HIGHLIGHT).ranges[0].toString(), "is wrong in a.rb.");
});

test("shown inside a closed <details>: it opens", () => {
  const div = thread();
  const details = div.querySelector("details");
  details.open = false;
  details.append(Object.assign(document.createElement("div"), { className: "p-bubble", textContent: "hidden claim" }));
  assert.equal(showClaim(div, { turn: "0a1b2c3d", q: "hidden claim" }, { roots: ".p-bubble", win: highlightWin() }), "quote");
  assert.equal(details.open, true);
});

test("a quote not in the turn marks the turn's opening; no turn is null; clearClaim takes the mark", () => {
  const div = thread();
  const win = highlightWin();
  // b.rb's sentence is the next turn's, not this one's.
  assert.equal(showClaim(div, { turn: "0a1b2c3d", q: "in b.rb too" }, { roots: ".p-bubble", win }), "turn");
  assert.ok(div.querySelector(`[data-turn-id="${TURN}"]`).classList.contains(HIT_CLASS));
  assert.equal(win.set.has(HIGHLIGHT), false);
  assert.equal(showClaim(div, { turn: "12345678", q: "x" }, { roots: ".p-bubble", win }), null);
  assert.equal(div.querySelectorAll(`.${HIT_CLASS}`).length, 0);
  win.set.set(HIGHLIGHT, {});
  showClaim(div, { turn: "0a1b2c3d", q: "" }, { roots: ".p-bubble", win });
  clearClaim(div, { win });
  assert.equal(div.querySelectorAll(`.${HIT_CLASS}`).length, 0);
  assert.equal(win.set.has(HIGHLIGHT), false);
});

test("without the Highlight API the bubble is still marked", () => {
  const div = thread();
  assert.equal(showClaim(div, { turn: "0a1b2c3d", q: "is wrong" }, { roots: ".p-bubble", win: {} }), "quote");
  assert.ok(div.querySelectorAll(".p-bubble")[1].classList.contains(HIT_CLASS));
});
