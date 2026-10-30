import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import {
  CHECK_NOT_ON_PAGE, nameVerdictCards, ownerCheckHash, placeVerdict,
} from "../../../lib/samagotchi/web/public/verdict_card.js";
import { claimFromHash } from "../../../lib/samagotchi/web/public/claim_link.js";

test("places a verdict on its source turn and links to the checking turn", () => {
  const win = new Window();
  const root = win.document.createElement("main");
  const source = win.document.createElement("div");
  source.dataset.turnId = "source-turn";
  const check = win.document.createElement("div");
  check.dataset.turnId = "check-turn";
  check.scrollIntoView = () => { check.scrolled = true; };
  root.append(source, check);
  const record = {
    anchor: { turn_id: "source-turn", quote: "the claim" },
    verdict: "refuted",
    reason: "The source says the opposite.",
    by: "p:alex",
    check_turn_id: "check-turn",
  };

  const card = placeVerdict(root, record, { who: "Alex", author: "p:alex" });

  assert.equal(card.textContent, "❌ refuted · Alexthe claimThe source says the opposite.View check");
  assert.equal(source.nextElementSibling, card);
  card.querySelector("a").dispatchEvent(new win.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(check.scrolled, true);
  assert.equal(placeVerdict(root, record, { who: "Alex", author: "p:alex" }), card);
  assert.equal(root.querySelectorAll(".verify-verdict").length, 1);
  win.happyDOM.abort();
});

test("keeps all card content as text and updates an unnamed author when their name loads", () => {
  const win = new Window();
  const root = win.document.createElement("main");
  const source = win.document.createElement("div");
  source.dataset.turnId = "source-turn";
  root.append(source);
  const record = {
    anchor: { turn_id: "source-turn", quote: "<script>claim</script>" },
    verdict: "confirmed",
    reason: "<img src=x>",
    by: "p:alex",
    check_turn_id: "check-turn",
  };

  const card = placeVerdict(root, record, { who: "A participant", author: "p:alex" });
  assert.equal(card.querySelector(".verify-verdict-quote").textContent, "<script>claim</script>");
  assert.equal(card.querySelector(".verify-verdict-reason").textContent, "<img src=x>");
  assert.equal(card.querySelector("img"), null);
  nameVerdictCards(root, (author) => author === "p:alex" ? "Alex" : null);
  assert.equal(card.querySelector(".verify-verdict-who").textContent, "Alex");
  win.happyDOM.abort();
});

test("does not place a verdict without a source turn", () => {
  const win = new Window();
  const root = win.document.createElement("main");

  assert.equal(placeVerdict(root, {
    anchor: { turn_id: "missing", quote: "claim" }, verdict: "unclear", reason: "No source.", check_turn_id: "check",
  }, { who: "You" }), null);
  win.happyDOM.abort();
});

test("View check unfolds what hides the checking turn before it scrolls there", () => {
  const win = new Window();
  const root = win.document.createElement("main");
  const source = win.document.createElement("div");
  source.dataset.turnId = "source-turn";
  const fold = win.document.createElement("details");
  const check = win.document.createElement("div");
  check.dataset.turnId = "check-turn";
  check.scrollIntoView = () => { check.scrolled = fold.open; };
  fold.append(check);
  root.append(source, fold);
  const record = {
    anchor: { turn_id: "source-turn", quote: "the claim" }, verdict: "confirmed", reason: "Yes.", check_turn_id: "check-turn",
  };

  placeVerdict(root, record).querySelector("a").dispatchEvent(new win.MouseEvent("click", { bubbles: true, cancelable: true }));

  assert.equal(check.scrolled, true);
  win.happyDOM.abort();
});

test("View check reports a missing turn to its caller", () => {
  const win = new Window();
  const root = win.document.createElement("main");
  const source = win.document.createElement("div");
  source.dataset.turnId = "source-turn";
  root.append(source);
  const record = {
    anchor: { turn_id: "source-turn", quote: "the claim" },
    verdict: "refuted",
    reason: "The source disagrees.",
    check_turn_id: "check-turn",
  };
  let missing = null;

  const card = placeVerdict(root, record, { onMissingCheck: (value) => { missing = value; } });
  const event = new win.MouseEvent("click", { bubbles: true, cancelable: true });
  card.querySelector("a").dispatchEvent(event);

  assert.equal(event.defaultPrevented, true);
  assert.equal(missing, record);
  assert.equal(CHECK_NOT_ON_PAGE, "That check is no longer on this page.");
  win.happyDOM.abort();
});

test("an owner check link targets another known session that contains its verdict", () => {
  const checkTurnId = "a1b2c3d4-0000";
  const hash = ownerCheckHash([
    { id: "current", verdicts: [{ check_turn_id: checkTurnId }] },
    { id: "continued", verdicts: [{ check_turn_id: checkTurnId }] },
  ], "current", checkTurnId);

  assert.equal(hash, "#/s/continued?t=a1b2c3d4");
  assert.deepEqual(claimFromHash(hash), {
    sessionId: "continued", turn: "a1b2c3d4", q: "", p: "",
  });
  assert.equal(ownerCheckHash([{ id: "current", verdicts: [{ check_turn_id: "check-turn" }] }],
    "current", "check-turn"), null);
});

// A turn as the owner's page draws it: the prompt, a steps block, the
// answer and its timing line, a gap divider, the next turn.
function ownerTurn(win, { answer = "Done: the claim holds in /proj/keys.rb.", step = "the claim, maybe" } = {}) {
  const doc = win.document;
  const root = doc.createElement("main");
  const make = (cls, text = "") => {
    const element = doc.createElement("div");
    element.className = cls;
    element.textContent = text;
    return element;
  };
  const prompt = make("bubble user");
  prompt.dataset.turnId = "source-turn";
  prompt.append(make("user-message", "Is the claim right?"));
  const block = doc.createElement("details");
  block.className = "turn-steps";
  block.append(make("gen-text", step));
  const output = make("bubble output", answer);
  const timing = make("turn-timing", "turn 1 · 4s");
  const gap = make("time-gap", "2 hours later");
  const next = make("bubble user", "next");
  next.dataset.turnId = "next-turn";
  root.append(prompt, block, output, timing, gap, next);
  return { root, prompt, block, output, timing, gap, next };
}

const OWNER_ROOTS = ".bubble.output, .bubble.user .user-message, .gen-text";

function verdictOn(quote, checkTurnId = "check-turn") {
  return {
    anchor: { turn_id: "source-turn", quote }, verdict: "unclear", reason: "Can't tell.", check_turn_id: checkTurnId,
  };
}

test("places the card after the answer that holds the quote, cards on one answer in order, once each", () => {
  const win = new Window();
  const { root, output, timing } = ownerTurn(win);

  const first = placeVerdict(root, verdictOn("the claim holds"), { roots: OWNER_ROOTS });
  const second = placeVerdict(root, verdictOn("the claim", "check-2"), { roots: OWNER_ROOTS });

  assert.equal(output.nextElementSibling, first);
  assert.equal(first.nextElementSibling, second);
  assert.equal(second.nextElementSibling, timing);
  assert.equal(placeVerdict(root, verdictOn("the claim holds"), { roots: OWNER_ROOTS }), first);
  assert.equal(root.querySelectorAll(".verify-verdict").length, 2);
  win.happyDOM.abort();
});

test("reads the quote as the page does (the session's folder relative)", () => {
  const win = new Window();
  const { root, output } = ownerTurn(win);

  const card = placeVerdict(root, verdictOn("holds in keys.rb"), { roots: OWNER_ROOTS, opts: { cwd: "/proj" } });

  assert.equal(output.nextElementSibling, card);
  win.happyDOM.abort();
});

test("a quote only in a step goes after the turn's steps block", () => {
  const win = new Window();
  const { root, block } = ownerTurn(win, { answer: "Something else." });

  const card = placeVerdict(root, verdictOn("the claim, maybe"), { roots: OWNER_ROOTS });

  assert.equal(block.nextElementSibling, card);
  win.happyDOM.abort();
});

test("a quote not found goes at the turn's end, before a gap divider, never above the turn", () => {
  const win = new Window();
  const { root, timing, gap } = ownerTurn(win);

  const card = placeVerdict(root, verdictOn("not on the page"), { roots: OWNER_ROOTS });

  assert.equal(timing.nextElementSibling, card);
  assert.equal(card.nextElementSibling, gap);
  win.happyDOM.abort();
});

test("a context note ends the source turn: a wake turn's answer after it never takes the card", () => {
  const win = new Window();
  const { root, timing, gap } = ownerTurn(win, { answer: "Something else." });
  const note = win.document.createElement("div");
  note.className = "bubble note";
  note.textContent = "note from c1";
  const wake = win.document.createElement("div");
  wake.className = "bubble output";
  wake.textContent = "Woken: the claim holds after all.";
  gap.before(note, wake);

  const card = placeVerdict(root, verdictOn("the claim holds"), { roots: OWNER_ROOTS });

  assert.ok(timing.nextElementSibling === card);
  assert.ok(card.nextElementSibling === note);
  win.happyDOM.abort();
});

test("participant page: after the reply that quotes it, not the prompt that says the same, and again after a redraw", () => {
  const win = new Window();
  const doc = win.document;
  const thread = doc.createElement("section");
  const message = (cls, text, turnId = null) => {
    const node = doc.createElement("div");
    node.className = `p-msg ${cls}`;
    if (turnId) node.dataset.turnId = turnId;
    const bubble = doc.createElement("div");
    bubble.className = "p-bubble";
    bubble.textContent = text;
    node.append(bubble);
    return node;
  };
  const nodes = [
    message("user", "Check: the claim holds", "source-turn"),
    message("reply", "Yes, the claim holds."),
    message("user", "Thanks", "next-turn"),
  ];
  thread.append(...nodes);
  const roots = ".p-msg > .p-bubble";

  const card = placeVerdict(thread, verdictOn("the claim holds"), { roots });
  assert.equal(nodes[1].nextElementSibling, card);

  // A redraw (participant.js syncChildren) drops the card; placed again, it
  // lands in the same place, once.
  thread.replaceChildren(...nodes);
  const again = placeVerdict(thread, verdictOn("the claim holds"), { roots });
  assert.equal(nodes[1].nextElementSibling, again);
  assert.equal(thread.querySelectorAll(".verify-verdict").length, 1);
  win.happyDOM.abort();
});
