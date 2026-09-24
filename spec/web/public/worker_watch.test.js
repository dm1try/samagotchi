import test from "node:test";
import assert from "node:assert/strict";
import { openStream, watchForWorker } from "../../../lib/samagotchi/web/public/data.js";

// A page on a session with no live worker has no stream, so a turn another
// client enqueues (it wakes a new worker) would never show. watchForWorker
// polls the session until a worker's event_seq appears.
function fakeTimers() {
  const pending = [];
  return {
    setTimeoutImpl: (fn, ms) => { pending.push({ fn, ms }); return pending.length; },
    clearTimeoutImpl: (h) => { if (pending[h - 1]) pending[h - 1].fn = null; },
    async tick() {
      const next = pending.shift();
      if (next?.fn) await next.fn();
    },
    get size() { return pending.filter((p) => p.fn).length; },
  };
}

test("watchForWorker calls onLive once a worker's event_seq shows up", async () => {
  const timers = fakeTimers();
  const answers = [{ last_event_seq: null }, { last_event_seq: null }, { last_event_seq: 7 }];
  const asked = [];
  const live = [];
  watchForWorker("s1", {
    getSessionImpl: async (id) => { asked.push(id); return answers.shift(); },
    onLive: (data) => live.push(data.last_event_seq),
    interval: 3000,
    ...timers,
  });

  await timers.tick();
  await timers.tick();
  assert.deepEqual(live, []);
  await timers.tick();
  assert.deepEqual(live, [7]);
  assert.deepEqual(asked, ["s1", "s1", "s1"]);
  assert.equal(timers.size, 0, "stops polling once live");
});

test("watchForWorker keeps polling through a failed request, and stop() ends it", async () => {
  const timers = fakeTimers();
  let calls = 0;
  const watch = watchForWorker("s1", {
    getSessionImpl: async () => { calls += 1; throw new Error("503"); },
    onLive: () => assert.fail("not live"),
    ...timers,
  });

  await timers.tick();
  assert.equal(calls, 1);
  assert.equal(timers.size, 1);
  watch.stop();
  await timers.tick();
  assert.equal(calls, 1);
});

class ClosingEventSource {
  constructor() { this.listeners = new Map(); this.readyState = 1; this.onerror = null; }
  addEventListener(type, fn) { this.listeners.set(type, fn); }
  close() { this.readyState = 2; }
}

test("openStream closes and reports a dropped stream instead of letting the browser reconnect with its cursor", () => {
  let es;
  const Impl = class extends ClosingEventSource { constructor(u) { super(u); es = this; } };
  const closed = [];
  openStream("s1", 0, { turn_started: () => {} }, { EventSourceImpl: Impl, onStreamClosed: () => closed.push(true) });

  es.listeners.get("turn_started")({ data: "{}" });
  es.readyState = 0; // the worker left; the browser would reconnect with Last-Event-ID
  es.onerror();
  es.onerror();
  assert.deepEqual(closed, [true]);
  assert.equal(es.readyState, 2);
});

test("watchForWorker calls onGone and stops once the session is gone (404)", async () => {
  const timers = fakeTimers();
  const gone = [];
  const notFound = Object.assign(new Error("not_found (404)"), { status: 404 });
  const answers = [{ last_event_seq: null }, notFound];
  watchForWorker("s1", {
    getSessionImpl: async () => { const a = answers.shift(); if (a instanceof Error) throw a; return a; },
    onLive: () => assert.fail("not live"),
    onGone: () => gone.push("s1"),
    ...timers,
  });
  await timers.tick();
  assert.deepEqual(gone, []);
  await timers.tick();
  assert.deepEqual(gone, ["s1"]);
  assert.equal(timers.size, 0, "stops polling once gone");
});

test("watchForWorker keeps polling through other errors (a server restart)", async () => {
  const timers = fakeTimers();
  const gone = [];
  watchForWorker("s1", {
    getSessionImpl: async () => { throw Object.assign(new Error("boom (500)"), { status: 500 }); },
    onLive: () => {},
    onGone: () => gone.push("s1"),
    ...timers,
  });
  await timers.tick();
  assert.deepEqual(gone, []);
  assert.equal(timers.size, 1);
});
