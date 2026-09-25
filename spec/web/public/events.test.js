import test from "node:test";
import assert from "node:assert/strict";
import { openEvents } from "../../../lib/samagotchi/web/public/data.js";

// GET /api/events as the page reads it: typed frames to typed handlers,
// and a fallback only when the browser gave up before the first frame.
class FakeEventSource {
  constructor(url) {
    this.url = url;
    this.listeners = new Map();
    this.closed = false;
    this.onerror = null;
    this.readyState = 0;
  }
  addEventListener(type, fn) {
    this.listeners.set(type, fn);
  }
  dispatch(type, data) {
    this.readyState = 1;
    this.listeners.get(type)?.({ data });
  }
  close() {
    this.closed = true;
    this.readyState = 2;
  }
}

function open(handlers, opts = {}) {
  let es;
  const Impl = class extends FakeEventSource { constructor(u) { super(u); es = this; } };
  const control = openEvents(handlers, { EventSourceImpl: Impl, ...opts });
  return { es, control };
}

test("parses each frame's JSON to its handler, scoped by ?dir", () => {
  const seen = [];
  const { es } = open({
    snapshot: (d) => seen.push(["snapshot", d.sessions.length]),
    session: (d) => seen.push(["session", d.session?.id]),
    session_gone: (d) => seen.push(["gone", d.id]),
  }, { dir: "/Users/me/proj" });

  assert.equal(es.url, "/api/events?dir=%2FUsers%2Fme%2Fproj");
  es.dispatch("snapshot", JSON.stringify({ sessions: [{ id: "a" }, { id: "b" }] }));
  es.dispatch("session", JSON.stringify({ session: { id: "c" } }));
  es.dispatch("session_gone", JSON.stringify({ id: "a" }));
  es.dispatch("session", "{ not json");
  assert.deepEqual(seen, [["snapshot", 2], ["session", "c"], ["gone", "a"], ["session", undefined]]);
});

test("without ?dir the URL has no query", () => {
  const { es } = open({});
  assert.equal(es.url, "/api/events");
});

test("onError fires only when the browser gave up before the first frame (no hub: 503)", () => {
  const errors = [];
  const { es, control } = open({ snapshot: () => {} }, { onError: () => errors.push(1) });

  es.readyState = 0; // CONNECTING: the browser will retry on its own (chi web restarting)
  es.onerror();
  assert.deepEqual(errors, []);
  assert.equal(control.live, true);

  es.readyState = 2; // CLOSED: a 503 or 400, no retry
  es.onerror();
  assert.deepEqual(errors, [1]);
  assert.equal(control.live, false);
  es.onerror();
  assert.deepEqual(errors, [1]);
});

test("after the first frame an error is the browser's to reconnect from: no fallback, still live", () => {
  const errors = [];
  const { es, control } = open({ snapshot: () => {} }, { onError: () => errors.push(1) });
  es.dispatch("snapshot", JSON.stringify({ sessions: [] }));
  es.readyState = 2;
  es.onerror();
  assert.deepEqual(errors, []);
  assert.equal(control.live, true);
  assert.equal(es.closed, false);

  control.close();
  assert.equal(es.closed, true);
  assert.equal(control.live, false);
});
