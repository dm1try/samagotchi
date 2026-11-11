import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createResyncReach, readFailed, REACH } from "../../../lib/samagotchi/web/public/resync_reach.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";
import { sessionBar } from "../../../lib/samagotchi/web/public/info_bar_model.js";
import { renderInfoBar } from "../../../lib/samagotchi/web/public/info_bar.js";
import { hintEl } from "../../../lib/samagotchi/web/public/bubbles.js";

const ID = "0123456789abcdef";

// The page as app.js wires it: the store, the history with a drawn
// conversation or select()'s "Loading…", and the bar drawn from the store.
function page({ running = false } = {}) {
  const store = createSessionStore({ initial: { ...emptySessionState(), status: "idle", model: "qwen" } });
  store.update({ selected: ID });
  const historyEl = document.createElement("div");
  const reach = createResyncReach({ store, historyEl, errorHint: (m) => hintEl(`Error: ${m}`) });
  const bar = () => sessionBar({
    id: ID, state: store.current, sessions: [{ id: ID }], versions: { served: "1.0.0", installed: null },
    cardTitle: () => "", continuing: new Set(), restarting: new Set(), streaming: false, running,
  }).bar;
  const infoEl = document.createElement("div");
  const statusEl = () => {
    renderInfoBar(infoEl, bar());
    return infoEl.querySelector(".status");
  };
  const loading = () => {
    historyEl.replaceChildren(hintEl("Loading…"));
    reach.loading();
  };
  const draw = () => {
    const bubble = document.createElement("div");
    bubble.className = "bubble user";
    bubble.textContent = "hello";
    historyEl.replaceChildren(bubble);
    reach.drawn(ID);
  };
  return { store, historyEl, reach, statusEl, loading, draw };
}

test("readFailed: nothing drawn shows the hint; a drawn history stays and says where the tries are", () => {
  assert.deepEqual(readFailed({ drawn: false, retrying: true }), { hint: true, reach: null });
  assert.deepEqual(readFailed({ drawn: false, retrying: false }), { hint: true, reach: null });
  assert.deepEqual(readFailed({ drawn: true, retrying: true }), { hint: false, reach: "reconnecting" });
  assert.deepEqual(readFailed({ drawn: true, retrying: false }), { hint: false, reach: "offline" });
});

test("a re-read that fails keeps the drawn history and the bar says retrying", () => {
  const p = page();
  p.loading();
  p.draw();
  p.reach.failed(ID, "Failed to fetch", { retrying: true });
  assert.equal(p.historyEl.textContent, "hello");
  assert.equal(p.store.current.reach, "reconnecting");
  assert.equal(p.reach.needsReread(), true);
  const status = p.statusEl();
  assert.equal(status.className, "status reconnecting");
  assert.equal(status.textContent, REACH.reconnecting.text);
  assert.equal(status.getAttribute("title"), REACH.reconnecting.tip);
});

test("the tries running out still keep the history: the bar says offline", () => {
  const p = page();
  p.loading();
  p.draw();
  p.reach.failed(ID, "Failed to fetch", { retrying: true });
  p.reach.failed(ID, "Failed to fetch", { retrying: false });
  assert.equal(p.historyEl.textContent, "hello");
  assert.equal(p.store.current.reach, "offline");
  assert.equal(p.statusEl().textContent, "offline");
  assert.equal(p.reach.needsReread(), true, "the hub's next event re-reads it");
});

test("a later re-read that draws the session clears the indicator", () => {
  const p = page();
  p.loading();
  p.draw();
  p.reach.failed(ID, "Failed to fetch", { retrying: false });
  p.draw();
  assert.equal(p.store.current.reach, null);
  assert.equal(p.reach.needsReread(), false);
  const status = p.statusEl();
  assert.equal(status.className, "status idle");
  assert.equal(status.textContent, "idle");
  assert.equal(status.hasAttribute("title"), false);
});

test("a first load that fails shows the error in the history, as before", () => {
  const p = page();
  p.loading();
  p.reach.failed(ID, "Failed to fetch", { retrying: true });
  assert.equal(p.historyEl.textContent, "Error: Failed to fetch");
  assert.equal(p.store.current.reach, null);
  assert.equal(p.statusEl().textContent, "idle");
});

test("another session's drawn history doesn't count: select()'s Loading… resets it", () => {
  const p = page();
  p.draw();
  p.loading();
  p.reach.failed(ID, "Failed to fetch", { retrying: false });
  assert.equal(p.historyEl.textContent, "Error: Failed to fetch");
});

test("a new session starts with no reach (forgetSession's emptySessionState)", () => {
  assert.equal(emptySessionState().reach, null);
});

test("the chip's words are short (the room it keeps for running/stopped); the full words are in its tooltip", () => {
  for (const r of Object.values(REACH)) {
    assert.ok(r.text.length <= 8 && !/\s/.test(r.text), r.text);
    assert.match(r.tip, /Can't reach chi web|can't reach chi web/);
  }
});

test("while its turn runs the chip keeps the turn's word: the stage says reconnecting… then", () => {
  const p = page({ running: true });
  p.store.update({ current: { status: "running" } });
  p.draw();
  p.reach.failed(ID, "Failed to fetch", { retrying: true });
  assert.equal(p.store.current.reach, "reconnecting");
  assert.equal(p.statusEl().textContent, "running");
});
