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
