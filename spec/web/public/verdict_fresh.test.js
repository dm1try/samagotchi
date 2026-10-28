import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import {
  freshURL, placeVerdictWithFresh, redrawFresh, settleRunning,
} from "../../../lib/samagotchi/web/public/verdict_fresh.js";

function page() {
  const win = new Window();
  const root = win.document.createElement("main");
  const source = win.document.createElement("div");
  source.dataset.turnId = "source-turn";
  root.append(source);
  return { win, root };
}

const unclear = {
  anchor: { turn_id: "source-turn", quote: "the claim" }, verdict: "unclear", reason: "Context doesn't say.",
  by: null, check_turn_id: "check-1",
};
const freshRecord = {
  anchor: { turn_id: "source-turn", quote: "the claim" }, verdict: "confirmed", reason: "keys.rb hashes it",
  by: "p:alex", check_turn_id: "check-2", fresh: true, of: "check-1", child_id: "child-id",
};

test("names the route by the session and the verdict", () => {
  assert.equal(freshURL("s 1", "c/1"), "/api/sessions/s%201/verdicts/c%2F1/fresh");
});

test("offers Verify fresh on an unclear card, marks it running once started, and links the owner to the child", async () => {
  const { win, root } = page();
  const running = [];
  const asked = [];
  const fresh = {
    verdicts: [unclear], running, canStart: true,
    start: async (of) => { asked.push(of); return { ok: true, child_id: "child-id" }; },
    childHref: (id) => `#/s/${id}`,
  };

  const card = placeVerdictWithFresh(root, unclear, { who: "You" }, fresh);
  const button = card.querySelector(".verify-fresh-btn");
  assert.equal(button.textContent, "Verify fresh");
  button.click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(asked, ["check-1"]);
  assert.deepEqual(running, [{ of: "check-1", child_id: "child-id" }]);
  assert.equal(card.querySelector(".verify-fresh-btn"), null);
  assert.equal(card.querySelector(".verify-fresh-running").textContent, "Verifying fresh… open its session");
  assert.equal(card.querySelector(".verify-fresh-running a").getAttribute("href"), "#/s/child-id");
  win.happyDOM.abort();
});

test("lands a fresh verdict on its original's card and ends the running check", () => {
  const { win, root } = page();
  const verdicts = [unclear, freshRecord];
  let running = [{ of: "check-1", child_id: "child-id" }];
  const fresh = () => ({ verdicts, running, canStart: true, start: async () => ({ ok: true }), childHref: (id) => `#/s/${id}` });

  const card = placeVerdictWithFresh(root, unclear, { who: "You" }, fresh());
  running = settleRunning(running, freshRecord);
  assert.deepEqual(running, []);
  assert.equal(placeVerdictWithFresh(root, freshRecord, { who: "Alex" }, fresh()), card);

  assert.equal(root.querySelectorAll(".verify-verdict").length, 1);
  assert.equal(card.querySelector(".verify-fresh-result").textContent, "fresh: ✅ confirmed — keys.rb hashes it · open its session");
  assert.equal(card.querySelector(".verify-fresh-running"), null);
  // Still unclear on its own: another fresh check may follow.
  assert.ok(card.querySelector(".verify-fresh-btn"));
  win.happyDOM.abort();
});

test("a participant sees the running check and the fresh verdict without a link, and no button when they can't run a turn", () => {
  const { win, root } = page();
  const fresh = { verdicts: [unclear], running: ["check-1"], canStart: true, start: async () => ({ ok: true }), childHref: () => null };

  const card = placeVerdictWithFresh(root, unclear, { who: "Owner" }, fresh);
  assert.equal(card.querySelector(".verify-fresh-running").textContent, "Verifying fresh…");
  assert.equal(card.querySelector(".verify-fresh-running a"), null);

  const idle = { verdicts: [unclear, freshRecord], running: [], canStart: false, start: async () => ({ ok: true }), childHref: () => null };
  placeVerdictWithFresh(root, unclear, { who: "Owner" }, idle);
  assert.equal(card.querySelector(".verify-fresh-btn"), null);
  assert.equal(card.querySelector(".verify-fresh-result a"), null);
  assert.equal(card.querySelectorAll(".verify-fresh").length, 1);
  win.happyDOM.abort();
});

test("a missing worker feature shows disabled Verify fresh with the restart hint", () => {
  const { win, root } = page();
  const fresh = {
    verdicts: [unclear], running: [], canStart: false,
    unavailableReason: "restart this session to use Verify",
  };
  const card = placeVerdictWithFresh(root, unclear, { who: "You" }, fresh);
  const button = card.querySelector(".verify-fresh-btn");
  assert.equal(button.textContent, "Verify fresh");
  assert.equal(button.disabled, true);
  assert.equal(button.title, "restart this session to use Verify");
  assert.equal(card.querySelector(".verify-fresh-unavailable").textContent, "restart this session to use Verify");
  win.happyDOM.abort();
});

test("offers nothing on a confirmed or refuted card, and says why a start was refused", async () => {
  const { win, root } = page();
  const refuted = { ...unclear, verdict: "refuted", check_turn_id: "check-3" };
  const refusing = { verdicts: [], running: [], canStart: true, start: async () => ({ ok: false, error: "cap reached" }) };
  const card = placeVerdictWithFresh(root, refuted, { who: "You" }, refusing);
  assert.equal(card.querySelector(".verify-fresh"), null);

  const open = placeVerdictWithFresh(root, unclear, { who: "You" }, refusing);
  open.querySelector(".verify-fresh-btn").click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(open.querySelector(".verify-fresh-error").textContent, "cap reached");
  assert.equal(open.querySelector(".verify-fresh-btn").disabled, false);
  win.happyDOM.abort();
});

test("a start error is kept in the page's errors, so a redraw with fresh cards shows it until the next attempt", async () => {
  const { win, root } = page();
  const errors = {};
  let ok = false;
  const mk = () => ({
    verdicts: [], running: [], errors, canStart: true,
    start: async () => (ok ? { ok: true } : { ok: false, error: "Couldn't start a fresh check." }),
  });
  const card = placeVerdictWithFresh(root, unclear, { who: "You" }, mk());
  card.querySelector(".verify-fresh-btn").click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(errors["check-1"], "Couldn't start a fresh check.");

  // The participant page drops and re-creates its cards on a redraw.
  root.querySelector(".verify-verdict").remove();
  const again = placeVerdictWithFresh(root, unclear, { who: "You" }, mk());
  assert.equal(again.querySelector(".verify-fresh-error").textContent, "Couldn't start a fresh check.");

  ok = true;
  again.querySelector(".verify-fresh-btn").click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(errors["check-1"], undefined);
  assert.equal(again.querySelector(".verify-fresh-error"), null);
  win.happyDOM.abort();
});

test("redrawFresh follows a gate that flipped: the disabled button becomes startable", () => {
  const { win, root } = page();
  const gated = { verdicts: [], running: [], canStart: false, unavailableReason: "restart this session to use Verify" };
  const card = placeVerdictWithFresh(root, unclear, { who: "You" }, gated);
  assert.equal(card.querySelector(".verify-fresh-btn").disabled, true);
  redrawFresh(root, { verdicts: [], running: [], canStart: true, start: async () => ({ ok: true }) });
  assert.equal(card.querySelector(".verify-fresh-btn").disabled, false);
  assert.equal(card.querySelector(".verify-fresh-unavailable"), null);
  win.happyDOM.abort();
});
