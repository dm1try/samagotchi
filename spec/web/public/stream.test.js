import test from "node:test";
import assert from "node:assert/strict";
import { openStream } from "../../../lib/samagotchi/web/public/data.js";

class FakeEventSource {
  constructor(url) {
    this.url = url;
    this.listeners = new Map();
    this.closed = false;
    this.onerror = null;
  }
  addEventListener(type, fn) {
    const list = this.listeners.get(type) || [];
    list.push(fn);
    this.listeners.set(type, list);
  }
  dispatch(type, raw = {}) {
    const list = this.listeners.get(type) || [];
    list.forEach((fn) => fn(raw));
  }
  fireError() {
    if (typeof this.onerror === "function") this.onerror();
  }
  close() {
    this.closed = true;
  }
}

const expectedTypes = [
  "generation_chunk",
  "generation_started",
  "generation_completed",
  "turn_started",
  "turn_completed",
  "turn_canceled",
  "tool_call_completed",
  "reset",
];

test("openStream registers a listener for every canonical event type", () => {
  const calls = [];
  openStream("abc", 0, {}, { EventSourceImpl: FakeEventSource });
  // no handlers supplied -> nothing registered, but also no throw
  assert.ok(true);
});

test("openStream dispatches JSON events to the right typed handler", () => {
  const url = "/api/sessions/abc/stream?from_seq=0";
  let es;
  const seen = {};
  const control = openStream(
    "abc",
    0,
    {
      generation_chunk: (data) => {
        seen.chunk = data.content;
      },
      turn_completed: (data) => {
        seen.completed = data.result.output;
      },
      reset: (data) => {
        seen.reset = data.session_state_snapshot;
      },
    },
    {
      EventSourceImpl: class extends FakeEventSource {
        constructor(u) {
          super(u);
          es = this;
        }
      },
    },
  );

  assert.equal(es.url, "/api/sessions/abc/stream?from_seq=0");
  assert.equal(typeof control.close, "function");

  es.dispatch("generation_chunk", { data: JSON.stringify({ content: "hel" }) });
  es.dispatch("turn_completed", {
    data: JSON.stringify({ result: { output: "done" } }),
  });
  es.dispatch("reset", {
    data: JSON.stringify({ type: "reset", session_state_snapshot: { status: "idle" } }),
  });

  assert.equal(seen.chunk, "hel");
  assert.equal(seen.completed, "done");
  assert.deepEqual(seen.reset, { status: "idle" });
  assert.equal(control.live, true);
});

test("openStream falls back to text when JSON.parse fails", () => {
  const seen = {};
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  openStream(
    "abc",
    0,
    { generation_chunk: (data) => { seen.r = data; } },
    { EventSourceImpl: Fake },
  );
  esHolder.es.dispatch("generation_chunk", { data: "not-json" });
  assert.deepEqual(seen.r, { text: "not-json" });
});

test("openStream listens for provider retries and plugin init waits", () => {
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  const seen = [];
  openStream("abc", 0, {
    generation_retrying: (d) => seen.push(["retry", d.attempt]),
    plugin_init_wait: (d) => seen.push(["wait", d.tasks.length]),
  }, { EventSourceImpl: Fake });
  esHolder.es.dispatch("generation_retrying", { data: JSON.stringify({ attempt: 2 }) });
  esHolder.es.dispatch("plugin_init_wait", { data: JSON.stringify({ tasks: [{}] }) });
  assert.deepEqual(seen, [["retry", 2], ["wait", 1]]);
});

test("openStream only registers listeners for supplied handlers", () => {
  const seen = [];
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  const control = openStream(
    "abc",
    3,
    { turn_started: () => { seen.push("turn_started"); } },
    { EventSourceImpl: Fake },
  );
  assert.equal(esHolder.es.url, "/api/sessions/abc/stream?from_seq=3");
  assert.equal(esHolder.es.listeners.has("generation_chunk"), false);
  assert.equal(esHolder.es.listeners.has("turn_started"), true);
  control.close();
  assert.equal(control.live, false);
  assert.equal(esHolder.es.closed, true);
});

test("non-integer from_seq defaults to 0", () => {
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  openStream("abc", undefined, {}, { EventSourceImpl: Fake });
  assert.equal(esHolder.es.url, "/api/sessions/abc/stream?from_seq=0");
});

// A cursor from a worker's snapshot (`<seq>-<epoch>`): a Bridge of another
// worker answers it with a reset instead of skipping events.
test("streams from a string event id as it is", () => {
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  openStream("abc", "40-1a2b3c4d", {}, { EventSourceImpl: Fake });
  assert.equal(esHolder.es.url, "/api/sessions/abc/stream?from_seq=40-1a2b3c4d");
});

test("onStreamError fires when connection closes before any events", () => {
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  let errorFired = 0;
  const control = openStream("abc", 0, {}, { EventSourceImpl: Fake, onStreamError: () => errorFired++ });
  esHolder.es.fireError();
  assert.equal(errorFired, 1);
  assert.equal(esHolder.es.closed, true);
  assert.equal(control.live, false);
});

test("onStreamError does not fire after events were received", () => {
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  let errorFired = 0;
  openStream("abc", 0, { generation_chunk: () => {} }, {
    EventSourceImpl: Fake,
    onStreamError: () => errorFired++,
  });
  esHolder.es.dispatch("generation_chunk", { data: JSON.stringify({ content: "x" }) });
  esHolder.es.fireError();
  assert.equal(errorFired, 0);
});

test("onStreamError does not fire after explicit close", () => {
  const esHolder = {};
  const Fake = class extends FakeEventSource {
    constructor(u) {
      super(u);
      esHolder.es = this;
    }
  };
  let errorFired = 0;
  const control = openStream("abc", 0, {}, { EventSourceImpl: Fake, onStreamError: () => errorFired++ });
  control.close();
  esHolder.es.fireError();
  assert.equal(errorFired, 0);
});
test("openStream delivers prompt_restored (a failed turn's prompt handed back)", () => {
  let es;
  let seen = null;
  openStream("abc", 0, { prompt_restored: (data) => { seen = data; } }, {
    EventSourceImpl: class extends FakeEventSource { constructor(url) { super(url); es = this; } },
  });

  es.dispatch("prompt_restored", { data: JSON.stringify({ prompt: "boom", origin: null }) });

  assert.deepEqual(seen, { prompt: "boom", origin: null });
});

test("openStream delivers the command and continue-offer events", () => {
  let es;
  const seen = [];
  const handlers = Object.fromEntries(["command_ran", "continue_offered", "continue_resolved"].map((t) => [t, () => seen.push(t)]));
  openStream("abc", 0, handlers, {
    EventSourceImpl: class extends FakeEventSource { constructor(url) { super(url); es = this; } },
  });

  ["command_ran", "continue_offered", "continue_resolved"].forEach((t) => es.dispatch(t, { data: "{}" }));

  assert.deepEqual(seen, ["command_ran", "continue_offered", "continue_resolved"]);
});

test("openStream hands a context_added (a note joined the conversation) to its handler", () => {
  let es;
  const seen = [];
  openStream("abc", 0, { context_added: (data) => seen.push(data.label) }, {
    EventSourceImpl: class extends FakeEventSource {
      constructor(url) {
        super(url);
        es = this;
      }
    },
  });

  es.dispatch("context_added", { data: JSON.stringify({ label: "slack", text: "x" }) });

  assert.deepEqual(seen, ["slack"]);
});

test("openStream hands a card (a plugin's) to its handler", () => {
  let es;
  const seen = [];
  openStream("abc", 0, { card: (data) => seen.push([data.id, data.title]) }, {
    EventSourceImpl: class extends FakeEventSource { constructor(url) { super(url); es = this; } },
  });

  es.dispatch("card", { data: JSON.stringify({ id: "c1", title: "Hello" }) });

  assert.deepEqual(seen, [["c1", "Hello"]]);
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
