// hash_intent.js: what the page's hash means for the open session — a session
// to open, the all-sessions view, or the start page (app.js selectFromHash).
import test from "node:test";
import assert from "node:assert/strict";
import { hashIntent } from "../../../lib/samagotchi/web/public/hash_intent.js";

const TURN = "0a1b2c3d-4567-890a-bcde-ef0123456789";

test("a session hash names its session, with or without a claim's query", () => {
  assert.deepEqual(hashIntent("#/s/abc123", { selected: null }), { kind: "session", id: "abc123" });
  assert.deepEqual(hashIntent("#/s/abc123", { selected: "abc123" }), { kind: "session", id: "abc123" });
  assert.deepEqual(hashIntent(`#/s/abc123?t=${TURN}&q=hello`, { selected: null }), { kind: "session", id: "abc123" });
  // The participant link's fragment, opened in this browser: the claim says
  // which session it belongs to.
  const claim = { sessionId: "abc123", turn: TURN, q: "hello", p: "" };
  assert.deepEqual(hashIntent(`#s=abc123&t=${TURN}`, { selected: null, claim }), { kind: "session", id: "abc123" });
});

test("the all-sessions view is its own place, even with a session still open", () => {
  assert.deepEqual(hashIntent("#/sessions", { selected: "abc123" }), { kind: "all" });
  assert.deepEqual(hashIntent("#/sessions", { selected: null }), { kind: "all" });
});

test("the start page's own hash clears a session that is open", () => {
  // "#/" typed in the address bar while a session is open: the URL says the
  // start page, so the page must go there rather than keep showing the
  // session and send into it.
  assert.deepEqual(hashIntent("#/", { selected: "abc123" }), { kind: "start" });
  assert.deepEqual(hashIntent("", { selected: "abc123" }), { kind: "start" });
  // Any other fragment isn't the start page: an anchor clicked in an answer
  // keeps the session open.
  assert.deepEqual(hashIntent("#some-heading", { selected: "abc123" }), { kind: "keep" });
  // Nothing to leave: nothing to do.
  assert.deepEqual(hashIntent("#/", { selected: null }), { kind: "keep" });
  assert.deepEqual(hashIntent("", {}), { kind: "keep" });
  assert.deepEqual(hashIntent(undefined), { kind: "keep" });
});
