import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createSessionSync, RESYNC_RETRIES, STREAM_RETRY_MS } from "../../../lib/samagotchi/web/public/session_sync.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";

// The microtasks a resolved read runs through (the awaits in resync).
const settle = () => new Promise((resolve) => setImmediate(resolve));

// A read the spec answers by hand: getSession returns it, resolve/reject settle it.
function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

// The page around the sync, every hook recording its name and arguments
// (+calls+); +read(id)+ answers getSession.
function fakePage({ read = async () => ({ messages: [] }) } = {}) {
  const calls = [];
  const rec = (name, ret) => (...args) => {
    calls.push([name, ...args]);
    return typeof ret === "function" ? ret(...args) : ret;
  };
  const store = createSessionStore({ initial: emptySessionState() });
  const historyEl = document.createElement("div");
  const emptyEl = document.createElement("div");
  const page = { calls, stopping: null, streams: [], read, names: () => calls.map((c) => c[0]) };
  const proxy = (prefix) => new Proxy({}, { get: (_, name) => rec(`${prefix}.${String(name)}`) });
  const liveTurn = { running: false, forget: rec("liveTurn.forget") };
  const deps = {
    store, historyEl, emptyEl,
    getSession: (...args) => {
      calls.push(["getSession", ...args]);
      return page.read(...args);
    },
    openStream: (id, fromSeq, handlers, opts) => {
      calls.push(["openStream", id, fromSeq]);
      const control = { live: false, close: rec("stream.close"), opts };
      page.streams.push(control);
      return control;
    },
    liveTurn,
    turnDom: proxy("turnDom"),
    questionCards: proxy("questionCards"),
    contextChips: { load: rec("contextChips.load") },
    participantsControl: { load: rec("participantsControl.load") },
    view: {
      forgetSession: rec("forgetSession"),
      renderSessionView: rec("renderSessionView"),
      endTurnView: rec("endTurnView"),
    },
    page: {
      clearNotice: rec("clearNotice"), setSessionHash: rec("setSessionHash"), setTurnRunning: rec("setTurnRunning"),
      setLiveStatus: rec("setLiveStatus"), replaceCard: rec("replaceCard"), addEndBubble: rec("addEndBubble"),
    },
    later: {
      handlers: () => ({}),
      composer: () => ({ decideVisit: rec("composer.decideVisit") }),
      focusPrompt: rec("focusPrompt"),
      sessionActions: () => ({ leaveGoneSession: rec("leaveGoneSession"), stoppingId: () => page.stopping }),
      ownerClaim: () => ({ showPending: rec("ownerClaim.showPending") }),
    },
  };
  return { page, store, historyEl, emptyEl, liveTurn, sync: createSessionSync(deps) };
}

const count = (page, name) => page.names().filter((n) => n === name).length;

test("select shows Loading… and forgets the last session before its read lands; the same session keeps Verify", async () => {
  const pending = deferred();
  const { page, sync, store, historyEl, emptyEl } = fakePage({ read: () => pending.promise });
  const opened = sync.select("s1");
  assert.equal(store.selected, "s1");
  assert.equal(historyEl.textContent, "Loading…");
  assert.ok(emptyEl.classList.contains("hidden"));
  assert.deepEqual(page.calls.find((c) => c[0] === "forgetSession"), ["forgetSession", { keepVerify: false }]);
  assert.deepEqual(page.calls.find((c) => c[0] === "setSessionHash"), ["setSessionHash", "s1"]);
  pending.resolve({ messages: [], last_event_seq: 4 });
  await opened;
  assert.deepEqual(page.calls.find((c) => c[0] === "openStream"), ["openStream", "s1", 4]);
  assert.deepEqual(page.calls.at(-1), ["focusPrompt", { open: false }]);

  page.read = async () => ({ messages: [] });
  await sync.select("s1");
  assert.deepEqual(page.calls.filter((c) => c[0] === "forgetSession").at(-1), ["forgetSession", { keepVerify: true }]);
});

// The fold of the asking card is this tab's (stage_waiting.js): it follows the
// session, and the one of a session the page leaves has no page to come back to.
test("opening another session drops the fold kept for the one left; a reselect of the same keeps it", async () => {
  const map = new Map([["chi_asking_fold:s1", JSON.stringify({ key: "q:1", with: 1 })]]);
  const session = {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
  const before = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", { value: session, configurable: true, writable: true });
  try {
    const { sync } = fakePage({ read: async () => ({ messages: [] }) });
    await sync.select("s1");
    assert.ok(map.get("chi_asking_fold:s1"), "the same session again: the fold stays");
    await sync.select("s2");
    assert.ok(map.get("chi_asking_fold:s1") === undefined, "the session left: its fold goes");
    assert.ok(map.get("chi_asking_fold:s2") === undefined, "and the new one has none yet");
  } finally {
    if (before) Object.defineProperty(globalThis, "sessionStorage", before);
    else delete globalThis.sessionStorage;
  }
});

test("the first select (no session open before) removes no fold: no \"null\" key", async () => {
  const removed = [];
  const map = new Map([["null", "kept"]]);
  const session = {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => { removed.push(k); map.delete(String(k)); },
  };
  const before = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", { value: session, configurable: true, writable: true });
  try {
    const { sync } = fakePage({ read: async () => ({ messages: [] }) });
    await sync.select("s1");
    assert.deepEqual(removed, [], "nothing removed on the first select");
    assert.equal(map.get("null"), "kept");
  } finally {
    if (before) Object.defineProperty(globalThis, "sessionStorage", before);
    else delete globalThis.sessionStorage;
  }
});

test("select gives the session a fresh re-read budget", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { page, sync } = fakePage({ read: async () => { throw Object.assign(new Error("offline"), { status: 0 }); } });
  await sync.select("s1");
  for (let i = 1; i <= RESYNC_RETRIES; i += 1) {
    t.mock.timers.tick(i * STREAM_RETRY_MS);
    await settle();
  }
  assert.equal(count(page, "getSession"), RESYNC_RETRIES + 1);
  await sync.select("s1");
  assert.equal(sync.retryResync("s1"), true, "a new budget: the select's own retry is scheduled");
});

test("a bridge_up while a resync is in flight runs one tail resync, not one per event", async () => {
  const first = deferred();
  const { page, sync, store } = fakePage({ read: () => first.promise });
  store.update({ selected: "s1" });
  const running = sync.resync();
  sync.followSelectedSession({ id: "s1", status: "idle", bridge_up: true });
  sync.followSelectedSession({ id: "s1", status: "idle", bridge_up: true });
  assert.equal(count(page, "getSession"), 1);
  page.read = async () => ({ messages: [] });
  first.resolve({ messages: [] });
  await running;
  await settle();
  assert.equal(count(page, "getSession"), 2);
  assert.equal(count(page, "renderSessionView"), 2);
});

test("a hub event with no bridge and nothing to re-read resyncs nothing", () => {
  const { page, sync, store } = fakePage();
  store.update({ selected: "s1" });
  sync.followSelectedSession({ id: "s1", status: "idle", bridge_up: false });
  assert.equal(count(page, "getSession"), 0);
  assert.equal(store.current.status, "idle");
});

test("a 404 leaves the gone session", async () => {
  const { page, sync, store } = fakePage({ read: async () => { throw Object.assign(new Error("gone"), { status: 404 }); } });
  store.update({ selected: "s1" });
  await sync.resync();
  assert.deepEqual(page.calls.find((c) => c[0] === "leaveGoneSession"), ["leaveGoneSession", "s1", "not_found"]);
  assert.equal(count(page, "renderSessionView"), 0);
});

test("a failed re-read keeps the drawn history and retries, backing off, until the tries run out", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { page, sync, store, historyEl } = fakePage();
  store.update({ selected: "s1" });
  await sync.resync();
  historyEl.textContent = "the conversation";
  page.read = async () => { throw Object.assign(new Error("offline"), { status: 0 }); };
  await sync.resync({ endText: "worker gone" });
  assert.equal(store.current.reach, "reconnecting");
  assert.equal(historyEl.textContent, "the conversation");
  for (let i = 1; i <= RESYNC_RETRIES; i += 1) {
    const before = count(page, "getSession");
    t.mock.timers.tick(i * STREAM_RETRY_MS - 1);
    await settle();
    assert.equal(count(page, "getSession"), before, `try ${i} waits ${i * STREAM_RETRY_MS} ms`);
    t.mock.timers.tick(1);
    await settle();
    assert.equal(count(page, "getSession"), before + 1);
  }
  assert.equal(store.current.reach, "offline");
  t.mock.timers.tick(60_000);
  await settle();
  assert.equal(count(page, "getSession"), RESYNC_RETRIES + 2);
  assert.equal(historyEl.textContent, "the conversation");
});

test("a first load that fails shows the error in the history", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { sync, historyEl } = fakePage({ read: async () => { throw Object.assign(new Error("boom"), { status: 500 }); } });
  await sync.select("s1");
  assert.ok(historyEl.textContent.includes("Error: boom"));
});

test("a read that lands after another session opened is dropped", async () => {
  const pending = deferred();
  const { page, sync, store } = fakePage({ read: () => pending.promise });
  store.update({ selected: "s1" });
  const running = sync.resync();
  store.update({ selected: "s2" });
  pending.resolve({ messages: [], last_event_seq: 1 });
  await running;
  assert.equal(count(page, "renderSessionView"), 0);
  assert.equal(count(page, "openStream"), 0);
});

test("a read without a live bridge streams nothing and shows the gone worker's end line again", async () => {
  const { page, sync, store } = fakePage({ read: async () => ({ messages: [] }) });
  store.update({ selected: "s1" });
  await sync.resync({ endText: "the worker left" });
  assert.equal(count(page, "openStream"), 0);
  assert.deepEqual(page.calls.find((c) => c[0] === "addEndBubble"), ["addEndBubble", "the worker left"]);
  assert.equal(sync.hasStream(), false);
});

test("hasStream is a stream object (also while it connects), streamLive its delivering", () => {
  const { page, sync, store } = fakePage();
  store.update({ selected: "s1" });
  sync.startStream("s1", 0);
  assert.equal(sync.hasStream(), true);
  assert.equal(sync.streamLive(), false);
  page.streams[0].live = true;
  assert.equal(sync.streamLive(), true);
});

test("followWokenWorker streams from the render's cursor once, from 0 as a guess without one", () => {
  const { page, sync, store } = fakePage();
  store.update({ selected: "s1" });
  sync.followWokenWorker();
  assert.deepEqual(page.calls.find((c) => c[0] === "openStream"), ["openStream", "s1", 0]);
  assert.equal(store.current.streamFromGuess, true);
  page.streams[0].live = true;
  sync.followWokenWorker();
  assert.equal(count(page, "openStream"), 1);
});

test("workerGone of a stream that had opened resyncs at once; one that never opened waits a moment", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { page, sync, store } = fakePage();
  store.update({ selected: "s1" });
  sync.startStream("s1", 3);
  page.streams[0].opts.onStreamClosed();
  assert.equal(sync.hasStream(), false);
  assert.equal(count(page, "getSession"), 1);
  await settle();

  sync.startStream("s1", 3);
  page.streams[1].opts.onStreamError();
  assert.equal(count(page, "getSession"), 1);
  t.mock.timers.tick(STREAM_RETRY_MS);
  assert.equal(count(page, "getSession"), 2);
  await settle();
});

test("workerGone during a stopped turn ends it now; another session's is ignored", async () => {
  const { page, sync, store, liveTurn } = fakePage();
  store.update({ selected: "s1" });
  liveTurn.running = true;
  page.stopping = "s1";
  sync.workerGone("s1");
  const end = page.calls.find((c) => c[0] === "endTurnView");
  assert.equal(end[1], "gone");
  assert.deepEqual(end[3], { stopped: true });
  assert.equal(count(page, "setLiveStatus"), 0, "a stop's status is the stop's");
  assert.equal(store.current.bridgeUp, false);
  await settle();

  const before = page.calls.length;
  sync.workerGone("other");
  assert.equal(page.calls.length, before);
});

test("closeStream resets the stage and closes the stream once; again is a no-op but for the reset", () => {
  const { page, sync, store } = fakePage();
  store.update({ selected: "s1" });
  sync.startStream("s1", 0);
  sync.closeStream();
  sync.closeStream();
  assert.equal(count(page, "stream.close"), 1);
  assert.equal(count(page, "turnDom.reset"), 2);
  assert.equal(sync.hasStream(), false);
});

test("closeLive closes the stream but keeps the handle; restart drops it and resyncs", async () => {
  const { page, sync, store } = fakePage();
  store.update({ selected: "s1" });
  sync.startStream("s1", 0);
  sync.closeLive();
  assert.equal(count(page, "stream.close"), 1);
  assert.equal(sync.hasStream(), true);
  sync.restart();
  assert.equal(count(page, "stream.close"), 2);
  assert.equal(sync.hasStream(), false);
  assert.equal(count(page, "getSession"), 1);
  await settle();
});
