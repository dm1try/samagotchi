// The participant page's glue (participant.js), in happy-dom over the real
// participant.html: fetch and EventSource are fakes the test drives, the
// timers mocked. participant_model.test.js covers the pure parts.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const HTML = fs.readFileSync(new URL("../../../lib/samagotchi/web/public/participant.html", import.meta.url), "utf8");
const BODY = HTML.slice(HTML.indexOf("<body>") + "<body>".length, HTML.indexOf("</body>")).replace(/<script[^]*?<\/script>/g, "");

const REVIEW = {
  viewer: { name: "Alex", can_comment: true },
  session: { id: "s1", title: "Plan", status: "idle" },
  subjects: [],
  participants: [],
  messages: [{ role: "user", content: "Say pong" }, { role: "assistant", content: "PONG" }],
  current_turn: null,
  waiting_for_owner: false,
  queued: { mine: [], others: 0 },
  last_event_id: "5-ab",
};

// The stream: the page's listeners, driven by emit (a filtered event) and
// fail (the browser gave up).
class FakeSource {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 2;
  static all = [];
  constructor(url) {
    this.url = url;
    this.readyState = FakeSource.OPEN;
    this.listeners = {};
    FakeSource.all.push(this);
  }
  addEventListener(type, fn) {
    (this.listeners[type] ||= []).push(fn);
  }
  close() {
    this.readyState = FakeSource.CLOSED;
  }
  emit(type, fields = {}) {
    if (this.readyState === FakeSource.CLOSED) return;
    for (const fn of this.listeners[type] || []) fn({ data: JSON.stringify({ type, ...fields }) });
  }
  fail() {
    this.readyState = FakeSource.CLOSED;
    this.onerror?.();
  }
}

const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });

// A request the test answers when it wants: answer(status, body), or
// drop() (a network error).
function deferred(path, options) {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { path, method: options?.method || "GET", body: options?.body, promise,
    answer: (status, body) => resolve(reply(status, body)), drop: () => reject(new TypeError("Failed to fetch")) };
}

// Lets the page's awaits run (fetch, json, the next step).
async function settle() {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
}

let instance = 0;
// The page opened on session s1; +respond+ answers each request at once
// (return undefined to leave it pending in +calls+).
async function openPage(t, { respond = (call) => (call.method === "GET" ? call.answer(200, REVIEW) : undefined) } = {}) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const saved = { fetch: globalThis.fetch, EventSource: globalThis.EventSource };
  const calls = [];
  globalThis.fetch = (path, options) => {
    const call = deferred(path, options);
    calls.push(call);
    respond(call);
    return call.promise;
  };
  FakeSource.all = [];
  globalThis.EventSource = FakeSource;
  document.body.innerHTML = BODY;
  document.body.className = "";
  document.body.dataset.session = "s1";
  t.after(() => {
    globalThis.fetch = saved.fetch;
    if (saved.EventSource) globalThis.EventSource = saved.EventSource;
    else delete globalThis.EventSource;
    document.body.innerHTML = "";
    delete document.body.dataset.session;
  });
  await import(`../../../lib/samagotchi/web/public/participant.js?page=${++instance}`);
  await settle();
  const $ = (id) => document.getElementById(id);
  const tick = async (ms) => { t.mock.timers.tick(ms); await settle(); };
  return { calls, $, tick, sources: FakeSource.all, posts: () => calls.filter((c) => c.method === "POST") };
}

const enter = (target) => target.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

test("participant page: a double Enter or a Send while one is in flight posts the comment once; the next goes after the answer", async (t) => {
  const { $, posts } = await openPage(t);
  assert.equal($("main").hidden, false);
  $("comment").value = "Is step 3 safe?";
  enter($("comment"));
  enter($("comment"));
  $("compose").requestSubmit($("send"));
  await settle();
  assert.equal(posts().length, 1);

  posts()[0].answer(202, { status: "accepted" });
  await settle();
  assert.equal($("comment").value, "");
  $("comment").value = "And step 4?";
  enter($("comment"));
  await settle();
  assert.equal(posts().length, 2);
  assert.match(posts()[1].body, /And step 4/);
});

test("participant page: a comment whose post fails can be sent again", async (t) => {
  const { $, posts } = await openPage(t);
  $("comment").value = "Is step 3 safe?";
  enter($("comment"));
  await settle();
  posts()[0].drop();
  await settle();
  assert.equal($("comment").value, "Is step 3 safe?");
  enter($("comment"));
  await settle();
  assert.equal(posts().length, 2);
});

test("participant page: a review that can't be read at open says it is retrying, and backs off until it reads", async (t) => {
  let gets = 0;
  const { $, calls, tick, sources } = await openPage(t, {
    respond: (call) => {
      gets++;
      if (gets === 1) call.drop();
      else if (gets === 2) call.answer(503, { error: "review_unavailable", detail: "the session's worker is starting" });
      else call.answer(200, REVIEW);
    },
  });
  assert.equal($("head").hidden, false, "never a blank page");
  assert.equal($("offline").hidden, false);
  assert.match($("offline").textContent, /can't reach the session — retrying/i);
  assert.equal(sources.length, 0);

  await tick(3000);
  assert.equal(calls.length, 2);
  assert.equal($("offline").hidden, false);
  await tick(3000);
  assert.equal(calls.length, 2, "the second retry waits longer");
  await tick(3000);
  assert.equal(calls.length, 3);
  assert.equal($("offline").hidden, true);
  assert.equal($("main").hidden, false);
  assert.match($("thread").textContent, /PONG/);
  assert.equal(sources.length, 1, "the stream opens once the review is read");
});

test("participant page: a re-read that fails after a turn boundary keeps the thread, says so, and retries", async (t) => {
  let gets = 0;
  const { $, calls, tick, sources } = await openPage(t, {
    respond: (call) => {
      gets++;
      if (gets === 2) call.drop();
      else call.answer(200, { ...REVIEW, messages: gets > 2 ? [...REVIEW.messages, { role: "user", content: "Next" }] : REVIEW.messages });
    },
  });
  sources[0].emit("turn_completed");
  await tick(120);
  assert.equal(calls.length, 2);
  assert.equal($("offline").hidden, false);
  assert.equal($("main").hidden, false);
  assert.match($("thread").textContent, /PONG/);
  await tick(3000);
  assert.equal(calls.length, 3);
  assert.equal($("offline").hidden, true);
  assert.match($("thread").textContent, /Next/);
});

test("participant page: a 401 ends the page with the server's words for revoked and expired", async (t) => {
  for (const [code, detail] of [["token_revoked", "this review link was revoked by the session's owner"],
    ["token_expired", "this review link expired: ask the session's owner for a new one"]]) {
    await t.test(code, async (tt) => {
      const { $ } = await openPage(tt, { respond: (call) => call.answer(401, { error: code, detail }) });
      assert.equal($("ended").hidden, false);
      assert.equal($("head").hidden, true);
      assert.equal($("endedText").textContent, `${detail[0].toUpperCase()}${detail.slice(1)}.`);
    });
  }
});

test("participant page: a comment that can't reach the session says so and stays in the box", async (t) => {
  const { $, posts } = await openPage(t);
  $("comment").value = "Is step 3 safe?";
  enter($("comment"));
  await settle();
  posts()[0].drop();
  await settle();
  assert.equal($("comment").value, "Is step 3 safe?");
  assert.equal($("error").hidden, false);
  assert.match($("error").textContent, /can't reach the session/i);
});
