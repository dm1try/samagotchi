// The participant page's glue (participant.js), in happy-dom over the real
// participant.html: fetch and EventSource are fakes the test drives, the
// timers mocked. participant_model.test.js covers the pure parts.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { Window } from "happy-dom";
import { COMPOSER_FOLD_KEY } from "../../../lib/samagotchi/web/public/composer_fold.js";

if (!("localStorage" in globalThis)) globalThis.localStorage = new Window().localStorage;

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
async function openPage(t, { respond = (call) => (call.method === "GET" ? call.answer(200, REVIEW) : undefined), fakeDate = false } = {}) {
  t.mock.timers.enable({ apis: fakeDate ? ["setTimeout", "Date"] : ["setTimeout"] });
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
  $("send").click();
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

test("participant page: a live verdict is placed on its source turn without waiting for the review reload", async (t) => {
  const verdict = {
    anchor: { turn_id: "source", quote: "the claim" },
    verdict: "refuted",
    reason: "The source says the opposite.",
    by: "p:alex",
    check_turn_id: "check",
  };
  const review = {
    ...REVIEW,
    viewer: { id: "alex", name: "Alex", can_comment: true },
    participants: [{ id: "alex", name: "Alex", kind: "human" }],
    messages: [
      { role: "user", content: "Original claim", turn_id: "source" },
      { role: "assistant", content: "The claim." },
      { role: "user", content: "Verify the claim", turn_id: "check" },
      { role: "assistant", content: "The source disagrees." },
    ],
  };
  const { $, sources } = await openPage(t, { respond: (call) => call.answer(200, review) });
  assert.equal($("thread").querySelectorAll(".verify-verdict").length, 0);

  sources[0].emit("turn_completed", { verdict });
  await settle();

  const card = $("thread").querySelector(".verify-verdict");
  assert.ok(card);
  assert.match(card.textContent, /❌ refuted · You/);
  assert.match(card.textContent, /the claim/);
  assert.match(card.textContent, /The source says the opposite/);
});

test("participant page: Verify fresh on an unclear card posts once, says it runs, and the fresh verdict lands there", async (t) => {
  const unclear = {
    anchor: { turn_id: "source", quote: "the claim" }, verdict: "unclear", reason: "Context doesn't say.",
    by: "p:alex", check_turn_id: "check",
  };
  const review = {
    ...REVIEW,
    viewer: { id: "alex", name: "Alex", can_comment: true, mode: "pair" },
    participants: [{ id: "alex", name: "Alex", kind: "human" }],
    messages: [{ role: "user", content: "Original claim", turn_id: "source" }, { role: "assistant", content: "The claim." }],
    verdicts: [unclear],
    fresh_running: [],
  };
  const { $, sources, posts } = await openPage(t, {
    respond: (call) => (call.method === "GET" ? call.answer(200, review) : call.answer(202, { of: "check", running: true })),
  });
  const card = () => $("thread").querySelector(".verify-verdict");
  card().querySelector(".verify-fresh-btn").click();
  await settle();

  assert.equal(posts().length, 1);
  assert.equal(posts()[0].path, "/api/sessions/s1/verdicts/check/fresh");
  assert.equal(card().querySelector(".verify-fresh-running").textContent, "Verifying fresh…");
  assert.equal(card().querySelector(".verify-fresh-btn"), null);

  sources[0].emit("verdict_recorded", {
    verdict: { ...unclear, verdict: "confirmed", reason: "keys.rb hashes it", check_turn_id: "fresh-check", fresh: true, of: "check" },
  });
  await settle();
  assert.equal($("thread").querySelectorAll(".verify-verdict").length, 1);
  assert.equal(card().querySelector(".verify-fresh-result").textContent, "fresh: ✅ confirmed — keys.rb hashes it");
  assert.equal(card().querySelector(".verify-fresh-running"), null);
});

test("participant page: the header says pairing for a pair grant, review otherwise", async (t) => {
  const pair = { ...REVIEW, viewer: { ...REVIEW.viewer, mode: "pair" } };
  const { $ } = await openPage(t, { respond: (call) => call.answer(200, pair) });
  assert.equal($("title").textContent, "Alex · pairing · Plan");
  assert.equal(document.title, "chi · Alex · pairing");
});

test("participant page: a review grant's header stays the review's", async (t) => {
  const { $ } = await openPage(t);
  assert.equal($("title").textContent, "Alex's review · Plan");
  assert.equal(document.title, "chi · Alex's review");
});

test("participant page: what is typed while a comment is in flight stays in the box after it is accepted", async (t) => {
  const { $, posts } = await openPage(t);
  $("comment").value = "Is step 3 safe?";
  enter($("comment"));
  await settle();
  $("comment").value = "Is step 3 safe? And step 4";
  posts()[0].answer(202, { status: "accepted" });
  await settle();
  assert.equal($("comment").value, "Is step 3 safe? And step 4");
});

test("participant page: an error under the box goes at the next edit, and at the next send", async (t) => {
  const { $, posts } = await openPage(t);
  const paste = new window.Event("paste", { cancelable: true });
  Object.defineProperty(paste, "clipboardData", { value: { files: [{ name: "a.png", type: "image/png", size: 10 }], items: [], getData: () => "" } });
  $("comment").dispatchEvent(paste);
  assert.equal($("error").hidden, false);
  $("comment").value = "A";
  $("comment").dispatchEvent(new window.Event("input"));
  assert.equal($("error").hidden, true);

  $("comment").dispatchEvent(paste);
  assert.equal($("error").hidden, false);
  $("comment").value = "B";
  enter($("comment"));
  await settle();
  assert.equal($("error").hidden, true, "cleared as the comment goes");
  posts()[0].answer(202, { status: "accepted" });
  await settle();
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

// happy-dom lays nothing out, so the header's height can't be measured
// here: what keeps it is that #offline is out of the header's rows (an
// absolute overlay on the thread's top) and a failed read leaves #note as
// it was.
test("participant page: a failed read is said over the thread, never as a header row, and leaves the note", async (t) => {
  assert.match(HTML, /\.p-offline\{position:absolute;/);
  let gets = 0;
  const { $, sources, tick } = await openPage(t, {
    respond: (call) => {
      gets++;
      if (gets === 2) call.answer(404, { error: "not_found" });
      else call.answer(200, REVIEW);
    },
  });
  assert.equal($("offline").closest(".p-head-in"), null, "not in the header's flex rows");
  assert.ok($("offline").parentElement === $("head"));
  const note = $("note").textContent;
  assert.match(note, /You can comment and ask/);
  sources[0].emit("turn_completed");
  await tick(120);
  assert.equal($("offline").hidden, false);
  assert.equal($("offline").textContent, "This session is gone.");
  assert.equal($("note").textContent, note);
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

// GETs after the first left pending, in +calls+, for the test to answer.
const firstReadOnly = (review = REVIEW) => {
  let gets = 0;
  return (call) => {
    if (call.method === "GET" && ++gets === 1) call.answer(200, review);
    else if (call.method === "POST") call.answer(202, { status: "accepted" });
  };
};

test("participant page: of two reads in flight, an older answer arriving last is dropped", async (t) => {
  const { $, calls, tick, sources } = await openPage(t, { respond: firstReadOnly() });
  sources[0].emit("turn_enqueued");
  await tick(120);
  $("comment").value = "Is step 3 safe?";
  enter($("comment"));
  await settle();
  const gets = calls.filter((c) => c.method === "GET");
  assert.equal(gets.length, 3);
  const mine = { ...REVIEW, queued: { mine: [{ enqueued_id: "q1", prompt: "Is step 3 safe?" }], others: 0 } };
  gets[2].answer(200, mine);
  await settle();
  gets[1].answer(200, REVIEW);
  await settle();
  assert.match($("queue").textContent, /Queued: Is step 3 safe\?/);
});

test("participant page: the reply's events that arrive while the review is re-read are replayed from its cursor, not lost", async (t) => {
  const running = (text, id) => ({ ...REVIEW, session: { ...REVIEW.session, status: "running" },
    current_turn: { prompt: "Go", text, tools: [] }, last_event_id: id });
  const { $, calls, tick, sources } = await openPage(t, { respond: firstReadOnly(running("Hel", "7-ab")) });
  assert.match(sources[0].url, /from_seq=7-ab/);
  assert.equal($("liveReply").textContent, "Hel");
  // Another participant's comment queues (a re-read); the reply goes on
  // while it is in flight, after the server cut its snapshot (seq 8).
  sources[0].emit("turn_enqueued");
  await tick(120);
  sources[0].emit("generation_chunk", { text: "lo" });
  calls.at(-1).answer(200, running("Hel", "8-ab"));
  await settle();
  assert.equal(sources.length, 2, "the stream again from the re-read's cursor");
  assert.equal(sources[0].readyState, FakeSource.CLOSED);
  assert.match(sources[1].url, /from_seq=8-ab/);
  sources[1].emit("generation_chunk", { text: "lo" });
  sources[1].emit("generation_chunk", { text: " world" });
  assert.equal($("liveReply").textContent, "Hello world");
});

test("participant page: a re-read keeps the tool overview folded state and messages drawn already", async (t) => {
  const tools = [{ tool: "read", path: "src/a.md", status: "ok" }, { tool: "read", path: "src/b.md", status: "ok" }];
  const messages = [{ role: "user", content: "Look" }, { role: "assistant", content: "Read both.", tools }];
  const running = { ...REVIEW, messages, current_turn: { prompt: "Again", text: "", tools }, last_event_id: "3-ab" };
  let gets = 0;
  const { $, tick, sources } = await openPage(t, {
    respond: (call) => call.answer(200, ++gets === 1 ? running : { ...running, last_event_id: "4-ab", queued: { mine: [], others: 1 } }),
  });
  const [done, current] = $("thread").querySelectorAll("details");
  assert.equal(done.open, false, "tool rows fold into one line");
  assert.equal(done.querySelector("summary").textContent, "read 2 files");
  assert.deepEqual([...done.querySelectorAll("li")].map((row) => row.textContent), ["read src/a.md", "read src/b.md"]);
  done.querySelector("summary").click();
  assert.equal(done.open, true, "the native details summary opens the names-only rows");
  done.open = false;
  current.open = false;
  const bubble = $("thread").querySelector(".p-msg.reply .p-bubble");

  sources[0].emit("generation_chunk", { text: "Hm" });
  assert.equal($("liveReply").querySelector("details").open, false, "the live reply's rows stay folded as it streams");
  sources[0].emit("turn_enqueued");
  await tick(120);
  assert.equal(gets, 2);
  const [doneAfter, currentAfter] = $("thread").querySelectorAll("details");
  assert.equal(doneAfter.open, false);
  assert.equal(currentAfter.open, false);
  assert.equal($("thread").querySelector(".p-msg.reply .p-bubble"), bubble, "a message drawn already is kept, not drawn again");
});

test("participant page: a live turn's tool overview updates without showing command text", async (t) => {
  const running = { ...REVIEW, current_turn: { prompt: "Work", text: "", tools: [] } };
  const { $, sources } = await openPage(t, { respond: (call) => call.answer(200, running) });

  sources[0].emit("tool_call_started", { tool: "execute", command: "secret command", iteration: 1, call_index: 0 });
  let details = $("liveReply").querySelector("details");
  assert.equal(details.querySelector("summary").textContent, "ran 1 command");
  assert.deepEqual([...details.querySelectorAll("li")].map((row) => row.textContent), ["execute"]);
  assert.doesNotMatch($("liveReply").textContent, /secret command/);

  sources[0].emit("tool_call_started", { tool: "edit", path: "src/engine.rb", iteration: 1, call_index: 1 });
  details = $("liveReply").querySelector("details");
  assert.equal(details.querySelector("summary").textContent, "ran 1 command · edited 1 file (engine.rb)");
  assert.deepEqual([...details.querySelectorAll("li")].map((row) => row.textContent), ["execute", "edit src/engine.rb"]);
});

test("participant page: history and the current prompt carry their turn ids", async (t) => {
  const review = { ...REVIEW, messages: [{ role: "user", content: "Earlier", turn_id: "turn-old" }],
    current_turn: { prompt: "Now", turn_id: "turn-live", text: "", tools: [] } };
  const { $ } = await openPage(t, { respond: (call) => call.answer(200, review) });

  assert.deepEqual([...$("thread").querySelectorAll(".p-msg.user")].map((node) => node.dataset.turnId), ["turn-old", "turn-live"]);
});

// Selects +node+'s text and lets the Annotate bar read it (its frame).
async function select(node) {
  const range = document.createRange();
  range.selectNodeContents(node);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  document.dispatchEvent(new window.Event("selectionchange"));
  await new Promise((r) => window.requestAnimationFrame(r));
}

test("participant page: Annotate quotes the Plan and a comment into the comment box, labelled, with the presets", async (t) => {
  document.body.dataset.annotatePresets = "Agreed|Why?";
  t.after(() => delete document.body.dataset.annotatePresets);
  const review = { ...REVIEW, subjects: [{ path: "docs/plan.md", text: "Step 3: drop the table", html: "<p>Step 3: drop the table</p>" }],
    messages: [{ role: "user", content: "Is it safe?", author: "p:2", author_name: "Sam" }, { role: "assistant", content: "PONG" }] };
  const { $ } = await openPage(t, { respond: (call) => call.answer(200, review) });
  const bar = document.getElementById("annotateBar");
  // The built-in Verify after the configured ones; no Copy link here (the owner's page has it).
  assert.deepEqual([...bar.querySelectorAll("button")].filter((b) => !b.hidden).map((b) => b.textContent), ["Annotate", "Agreed", "Why?", "Verify"]);
  $("comment").value = "First:";
  await select($("planDoc").querySelector("p"));
  assert.equal(bar.hidden, false);
  bar.querySelector(".annotate-main").click();
  assert.equal($("comment").value, "First:\n\nFrom docs/plan.md:\n> Step 3: drop the table\n\n");
  assert.equal(document.activeElement, $("comment"));
  assert.equal($("comment").selectionStart, $("comment").value.length);
  assert.equal(bar.hidden, true);

  await select($("thread").querySelector(".p-msg.user .p-bubble"));
  bar.querySelector(".annotate-preset").click();
  assert.match($("comment").value, /\n\nFrom Sam's comment:\n> Is it safe\?\n\nAgreed$/);
  // A tool-less status line, the header: no bar.
  await select($("title"));
  assert.equal(bar.hidden, true);
});

test("participant page: no Annotate while the participant can't comment", async (t) => {
  const review = { ...REVIEW, viewer: { name: "Alex", can_comment: false, cap_reached: true } };
  const { $ } = await openPage(t, { respond: (call) => call.answer(200, review) });
  await select($("thread").querySelector(".p-msg.reply .p-bubble"));
  assert.equal(document.getElementById("annotateBar").hidden, true);
});

test("participant page: the page is the dynamic viewport's height (the dock above a phone's URL bar), 100% where unknown", () => {
  assert.match(HTML, /html,body\{height:100%;height:100dvh\}/);
});

test("participant page: after a turn ends, the next turn's events wait for the re-read, never added to the ended reply", async (t) => {
  const running = (prompt, text, id) => ({ ...REVIEW, session: { ...REVIEW.session, status: "running" },
    current_turn: { prompt, text, tools: [] }, last_event_id: id });
  const { $, calls, tick, sources } = await openPage(t, { respond: firstReadOnly(running("First", "Done.", "7-ab")) });
  sources[0].emit("turn_completed");
  sources[0].emit("turn_started");
  sources[0].emit("generation_chunk", { text: "Next" });
  assert.equal($("liveReply").textContent, "Done.", "the ended turn's reply is left as it was");
  await tick(120);
  calls.at(-1).answer(200, running("Second", "Next", "10-ab"));
  await settle();
  assert.match(sources.at(-1).url, /from_seq=10-ab/);
  sources.at(-1).emit("generation_chunk", { text: " one" });
  assert.equal($("liveReply").textContent, "Next one");
});

// A link's #code= opened in a browser that already has a session: the trade
// would replace it (a link sent to the owner swapping their cookie for a
// participant's), so the page asks first; declined, the code is dropped
// unused and the page goes on as it was.
test("participant page: a #code= link asks before replacing the session, and a no trades nothing", async (t) => {
  const saved = { location: globalThis.location, history: globalThis.history, confirm: globalThis.confirm };
  const asked = [];
  const replaced = [];
  globalThis.location = { hash: "#code=chc_x&s=s1", pathname: "/", search: "", reload: () => {} };
  globalThis.history = { replaceState: (_s, _t, url) => replaced.push(url) };
  globalThis.confirm = (text) => { asked.push(text); return false; };
  t.after(() => Object.assign(globalThis, saved));
  const { calls } = await openPage(t, {
    respond: (call) => (call.path === "/api/token" ? call.answer(401, {}) : call.method === "GET" ? call.answer(200, REVIEW) : undefined),
  });
  assert.equal(asked.length, 1);
  assert.match(asked[0], /in place of the session it has now/);
  assert.deepEqual(replaced, ["/#s=s1"]);
  assert.equal(calls.filter((c) => c.path === "/api/token").length, 0);
  assert.ok(calls.some((c) => c.path.endsWith("/review")));
});

// A claim link (claim_link.js) opened on the page: its quote marked once
// the thread is drawn; a turn this session doesn't have says so.
const TURNED = { ...REVIEW, messages: [{ role: "user", content: "Say pong", turn_id: "0a1b2c3d-0000" }, { role: "assistant", content: "PONG" }] };
async function openAt(t, hash) {
  const saved = { location: globalThis.location, history: globalThis.history };
  t.after(() => Object.assign(globalThis, saved));
  const replaced = [];
  globalThis.location = { hash, pathname: "/", search: "" };
  globalThis.history = { replaceState: (_s, _t, url) => replaced.push(url) };
  return { ...(await openPage(t, { respond: (call) => (call.method === "GET" ? call.answer(200, TURNED) : undefined) })), replaced };
}

test("participant page: a claim link marks its quote's reply, and the hash drops the claim", async (t) => {
  const { $, replaced } = await openAt(t, "#s=s1&t=0a1b2c3d&q=PONG");
  assert.ok($("thread").querySelector(".p-msg.reply .p-bubble").classList.contains("claim-hit"));
  assert.equal($("claimNote").hidden, true);
  // Opened again, the same link is a hashchange.
  assert.deepEqual(replaced, ["/#s=s1"]);
});

test("participant page: a claim link whose turn and quote this session doesn't have says so", async (t) => {
  const { $, tick } = await openAt(t, "#s=s1&t=99999999&q=nowhere");
  assert.equal($("thread").querySelectorAll(".claim-hit").length, 0);
  assert.equal($("claimNote").hidden, false);
  assert.equal($("claimNote").textContent, "The linked turn isn't in this session.");
  await tick(6000);
  assert.equal($("claimNote").hidden, true);
});

test("participant page: a claim link to an unstamped turn finds its quote in the thread", async (t) => {
  const { $ } = await openAt(t, "#s=s1&t=99999999&q=PONG");
  assert.ok($("thread").querySelector(".p-msg.reply .p-bubble").classList.contains("claim-hit"));
  assert.equal($("claimNote").hidden, true);
});

test("participant page: a claim link for another session says this browser holds this one's", async (t) => {
  const { $ } = await openAt(t, "#s=s2&t=0a1b2c3d&q=PONG");
  assert.equal($("thread").querySelectorAll(".claim-hit").length, 0);
  assert.equal($("claimNote").hidden, false);
  assert.equal($("claimNote").textContent, 'This link is for another session; this browser holds your link for "Plan".');
});

// The comment box: the shared composer (composer_mount.js) with a subset on.
const REVIEW_G1 = { ...REVIEW, viewer: { ...REVIEW.viewer, id: "g1", kind: "participant" } };
const key = (target, k, opts = {}) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts });
  target.dispatchEvent(e);
  return e;
};

test("participant page: ↑ recalls this grant's own comments from this browser, never the owner's history or another grant's", async (t) => {
  localStorage.setItem("chi_review_history:g2", JSON.stringify(["Another grant's comment"]));
  localStorage.setItem("chi_review_history:g1", "not json");
  t.after(() => {
    localStorage.removeItem("chi_review_history:g1");
    localStorage.removeItem("chi_review_history:g2");
  });
  const { $, calls, posts } = await openPage(t, { respond: firstReadOnly(REVIEW_G1) });
  $("comment").dispatchEvent(new window.Event("focus"));
  await settle();
  assert.equal(key($("comment"), "ArrowUp").defaultPrevented, false, "an unreadable list is no list");

  for (const text of ["Is step 3 safe?", "And step 4?"]) {
    $("comment").value = text;
    enter($("comment"));
    await settle();
  }
  assert.equal(posts().length, 2);
  assert.deepEqual(JSON.parse(localStorage.getItem("chi_review_history:g1")), ["Is step 3 safe?", "And step 4?"]);
  assert.equal(localStorage.getItem("chi_review_history:g2"), null, "another link's list goes at the first read");
  assert.equal($("comment").value, "");
  key($("comment"), "ArrowUp");
  assert.equal($("comment").value, "And step 4?");
  key($("comment"), "ArrowUp");
  assert.equal($("comment").value, "Is step 3 safe?");
  key($("comment"), "ArrowDown");
  key($("comment"), "ArrowDown");
  assert.equal($("comment").value, "", "past the newest, the draft there was");
  assert.equal(calls.filter((c) => c.path.includes("/api/history")).length, 0, "never the owner's prompt history");
});

test("participant page: a comment is always a plain queued turn: Alt+Enter sends the same, a `/` line opens no list, images stay out", async (t) => {
  const { $, posts } = await openPage(t, { respond: firstReadOnly(REVIEW_G1) });
  t.after(() => localStorage.removeItem("chi_review_history:g1"));
  assert.equal(document.getElementById("commandList"), null, "no `/` completion on this page");
  $("comment").value = "/cut";
  $("comment").dispatchEvent(new window.Event("input"));
  enter($("comment"));
  await settle();
  $("comment").value = "Later";
  key($("comment"), "Enter", { altKey: true });
  await settle();
  assert.deepEqual(posts().map((c) => JSON.parse(c.body)), [{ prompt: "/cut" }, { prompt: "Later" }]);
  assert.ok(posts().every((c) => c.path === "/api/sessions/s1/turn"));

  assert.equal($("attachBtn").hidden, true);
  const paste = new window.Event("paste", { cancelable: true });
  Object.defineProperty(paste, "clipboardData", { value: { files: [{ name: "a.png", type: "image/png", size: 10 }], items: [], getData: () => "" } });
  $("comment").dispatchEvent(paste);
  assert.equal($("chips").hidden, true);
  assert.equal($("chips").children.length, 0);
  assert.match($("error").textContent, /Images can't go in a review comment yet/);
});

test("participant page: the fold: a saved fold folds the box, Annotate opens it for the visit only", async (t) => {
  localStorage.setItem(COMPOSER_FOLD_KEY, "1");
  t.after(() => localStorage.removeItem(COMPOSER_FOLD_KEY));
  const review = { ...REVIEW_G1, subjects: [{ path: "docs/plan.md", text: "Step 3", html: "<p>Step 3</p>" }] };
  const { $ } = await openPage(t, { respond: (call) => call.answer(200, review) });
  assert.ok(document.body.classList.contains("has-session"));
  assert.ok(document.body.classList.contains("composer-folded"));
  assert.equal($("composeGrip").getAttribute("aria-expanded"), "false");
  await select($("planDoc").querySelector("p"));
  document.getElementById("annotateBar").querySelector(".annotate-main").click();
  assert.equal(document.body.classList.contains("composer-folded"), false);
  assert.equal($("comment").value, "From docs/plan.md:\n> Step 3\n\n");
  assert.ok($("composeGrip").classList.contains("draft") === false, "open: no folded draft mark");
  assert.equal(localStorage.getItem(COMPOSER_FOLD_KEY), "1", "opened for the visit, the saved fold kept");
});

test("participant page: a link that ends forgets this grant's comments", async (t) => {
  localStorage.setItem("chi_review_history:g1", JSON.stringify(["Mine"]));
  t.after(() => localStorage.removeItem("chi_review_history:g1"));
  let gets = 0;
  const { tick, sources } = await openPage(t, {
    respond: (call) => (++gets === 1 ? call.answer(200, REVIEW_G1)
      : call.answer(401, { error: "token_revoked", detail: "this review link was revoked by the session's owner" })),
  });
  assert.equal(localStorage.getItem("chi_review_history_session:s1"), "g1");
  sources[0].emit("turn_completed");
  await tick(120);
  assert.equal(document.getElementById("ended").hidden, false);
  assert.equal(localStorage.getItem("chi_review_history:g1"), null);
  assert.equal(localStorage.getItem("chi_review_history_session:s1"), null);
});

test("participant page: an ended link before its first read forgets only its remembered grant", async (t) => {
  localStorage.setItem("chi_review_history:g1", JSON.stringify(["Mine"]));
  localStorage.setItem("chi_review_history:g2", JSON.stringify(["Other"]));
  localStorage.setItem("chi_review_history_session:s1", "g1");
  t.after(() => {
    localStorage.removeItem("chi_review_history:g1");
    localStorage.removeItem("chi_review_history:g2");
    localStorage.removeItem("chi_review_history_session:s1");
  });
  const { $ } = await openPage(t, {
    respond: (call) => call.answer(401, { error: "token_revoked", detail: "this review link was revoked" }),
  });
  assert.equal($("ended").hidden, false);
  assert.equal(localStorage.getItem("chi_review_history:g1"), null);
  assert.equal(localStorage.getItem("chi_review_history:g2"), JSON.stringify(["Other"]));
  assert.equal(localStorage.getItem("chi_review_history_session:s1"), null);
});

test("participant page: the owner's participant view mounts no composer", async (t) => {
  document.body.dataset.viewer = "owner";
  t.after(() => delete document.body.dataset.viewer);
  const owner = { ...REVIEW, viewer: { kind: "owner", can_comment: false } };
  const { $, posts } = await openPage(t, { respond: (call) => call.answer(200, owner) });
  assert.equal($("dock").hidden, true);
  assert.equal(document.body.classList.contains("has-session"), false);
  assert.equal($("composeGrip").hasAttribute("role"), false, "no grip handlers drew it");
  $("comment").value = "Sneaky";
  enter($("comment"));
  $("send").click();
  key(document.body, "x");
  await settle();
  assert.equal(posts().length, 0);
  assert.equal(document.body.classList.contains("composer-folded"), false);
});

test("participant page: the usage row under the comment box shows the participant's own figures, again at each re-read", async (t) => {
  const expires = new Date(Date.now() + 6 * 24 * 3600 * 1000 + 60000).toISOString();
  const usage = { spent: 0.42, cap: 2, queued: 1, queue_limit: 3, expires_at: expires, model: "deepseek-v4" };
  let review = { ...REVIEW, viewer: { ...REVIEW.viewer, usage } };
  const { $, tick, sources } = await openPage(t, { respond: (call) => call.method === "GET" && call.answer(200, review) });
  const items = () => [...$("usage").children].map((span) => [span.dataset.key, span.textContent, span.className]);
  assert.equal($("usage").hidden, false);
  assert.deepEqual(items(), [["spent", "$0.42 of $2.00 cap", ""], ["queued", "1/3 queued", ""],
    ["expires_at", "link: 6 d left", ""], ["model", "deepseek-v4", "model"]]);
  assert.match($("usage").children[0].title, /cost the owner so far, of the \$2\.00 cap/);

  review = { ...REVIEW, viewer: { ...REVIEW.viewer, can_comment: false, cap_reached: true, usage: { ...usage, spent: 2.01, queued: 0 } } };
  sources[0].emit("turn_completed");
  await tick(120);
  assert.deepEqual(items().slice(0, 2), [["spent", "$2.01 of $2.00 cap", "over"], ["queued", "0/3 queued", ""]]);
});

test("participant page: the link's time left refreshes each minute and ends without a re-read", async (t) => {
  const { $, tick, calls } = await openPage(t, {
    fakeDate: true,
    respond: (call) => call.answer(200, { ...REVIEW, viewer: { ...REVIEW.viewer,
      usage: { expires_at: new Date(Date.now() + 125_000).toISOString() } } }),
  });
  const expiry = () => $("usage").querySelector('[data-key="expires_at"]').textContent;
  assert.equal(expiry(), "link: 2 min left");
  await tick(60_000);
  assert.equal(expiry(), "link: 1 min left");
  await tick(120_000);
  assert.equal(expiry(), "link ended");
  assert.equal(calls.length, 1, "expiry redraws do not request the review again");
});

test("participant page: no usage row without usage (an older chi web)", async (t) => {
  const { $ } = await openPage(t);
  assert.equal($("usage").hidden, true);
  assert.equal($("usage").children.length, 0);
});
