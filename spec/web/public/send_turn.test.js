// The composer's send (send_turn.js) over stand-in hooks: the start page's
// create, the echo and the ack, a fast failure's restore, chips added
// meanwhile, a switch while the send is in flight, and each error's place.
// The routes are composer.js' (composer.test.js), the restore rules
// restore.js'.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createSendTurn } from "../../../lib/samagotchi/web/public/send_turn.js";
import { routeComposerLine } from "../../../lib/samagotchi/web/public/composer.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

function failure(code, message = "boom", body = null) {
  return Object.assign(new Error(message), { status: 409, code, body });
}

// +sendTurn+ / +createIdleSession+: the data.js stand-ins (each call logged).
function harness({ open = "s1", text = "hello", chips = [], state = {}, running = false, pendingPick = null, reviewSubjects = null,
                   verify = null, revise = null, toolkitPicked = false, sendTurn = async () => ({ enqueued_id: "e1" }),
                   createIdleSession = async () => ({ id: "new1" }) } = {}) {
  // world.state reads the page's session store; setting it is a session
  // switch (forgetSession's replaceCurrent).
  const store = createSessionStore({ initial: { owner: "worker", commands: [], firstPreview: "first", ...state } });
  const world = {
    selected: open, chips,
    get state() { return store.current; },
    set state(fields) { store.replaceCurrent(fields); },
  };
  const log = [];
  const calls = [];
  const toasts = [];
  const bubbles = [];
  const historyEl = document.createElement("div");
  const promptEl = { value: text };
  const button = { disabled: false };
  const sentIds = new Set();
  const earlyRestores = new Map();
  // The page's redraws, registered as app.js registers them.
  store.on("composer", () => log.push("composerMode"));
  store.on("infoBar", () => log.push("infoBar"));
  let cleared = 0;
  const sendTurnApi = createSendTurn({
    session: () => world.selected,
    store,
    running: () => running,
    clientId: "web:t1",
    sentIds,
    earlyRestores,
    api: {
      createIdleSession: async (opts) => { calls.push(["create", opts]); return createIdleSession(opts); },
      uploadImage: async (id, _file, name) => { calls.push(["upload", id, name]); return { file: `${name}.png` }; },
      sendTurn: async (...args) => { calls.push(["turn", ...args]); return sendTurn(...args); },
    },
    verify: () => verify,
    clearVerify: () => { verify = null; },
    restoreVerify: (anchor) => { verify = anchor; },
    revise: () => revise,
    clearRevise: () => { revise = null; },
    restoreRevise: (anchor) => { revise = anchor; },
    dir: "/proj",
    startPage: {
      pendingPick: () => pendingPick,
      chosenModel: () => "qwen",
      newChoices: () => ({ llm_context: undefined, thinking: "high" }),
      clearChoices: () => log.push("clearChoices"),
      ...(reviewSubjects ? { reviewSubjects: () => reviewSubjects,
                             reviewRefused: (message) => { log.push(["reviewRefused", message]); return true; } } : {}),
      toolkitRefused: (message) => { log.push(["toolkitRefused", message]); return toolkitPicked; },
    },
    takeDelivery: () => null,
    composer: {
      el: promptEl,
      button,
      chips: () => world.chips,
      setChips: (list) => { world.chips = list; },
      fit: () => {},
      clear: () => { cleared += 1; promptEl.value = ""; },
      openForVisit: () => log.push("openForVisit"),
      focus: () => log.push("focus"),
      noteDraft: (id) => log.push(`noteDraft ${id}`),
    },
    historyEl,
    turnDom: { handOff: () => {}, holds: () => false },
    makeUserBubble: (prompt, opts) => {
      const el = document.createElement("div");
      if (opts.delivery) el.dataset.delivery = opts.delivery;
      historyEl.append(el);
      bubbles.push({ prompt, opts, el });
      return el;
    },
    bubbleById: () => null,
    addCommandBubble: (view) => log.push(["commandBubble", view]),
    addCreatedSession: (created) => log.push(`created ${created.id}`),
    select: async (id) => { log.push(`select ${id}`); world.selected = id; world.state = { owner: null, commands: [] }; },
    showNotice: (text) => log.push(["notice", text]),
    followWokenWorker: () => log.push("follow"),
    refreshHistory: () => log.push("refreshHistory"),
    leaveGoneSession: (id, why) => log.push(`gone ${id} ${why}`),
    runCommand: (command) => log.push(["command", command]),
    toast: (text, action, options) => toasts.push({ text, options }),
    alert: (text) => log.push(["alert", text]),
  });
  return { send: sendTurnApi.send, world, log, calls, toasts, bubbles, promptEl, button, sentIds, earlyRestores,
           cleared: () => cleared, verify: () => verify, revise: () => revise };
}

test("a line in a session: the echo, POST /turn with the tab's id, the composer emptied at the ack, the stream followed", async () => {
  const h = harness();
  await h.send();
  assert.deepEqual(h.calls, [["turn", "s1", "hello", { clientId: "web:t1", images: [], history: true, delivery: null }]]);
  assert.equal(h.bubbles.length, 1);
  assert.ok(h.bubbles[0].el.parentNode);
  assert.equal(h.bubbles[0].el.dataset.enqueuedId, "e1");
  assert.ok(h.sentIds.has("e1"));
  assert.equal(h.promptEl.value, "");
  assert.deepEqual(h.log, ["refreshHistory", "follow", "focus"]);
  assert.equal(h.button.disabled, false);
});

test("a Verify selection's anchor travels with edited text; an ordinary send has no anchor", async () => {
  const anchor = { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim" };
  const h = harness({ text: "edited verification prompt", verify: anchor });
  await h.send();
  assert.deepEqual(h.calls[0], ["turn", "s1", "edited verification prompt",
    { clientId: "web:t1", images: [], history: true, delivery: null, verify: anchor }]);
  assert.equal(h.verify(), null);

  const plain = harness();
  await plain.send();
  assert.deepEqual(plain.calls[0][3], { clientId: "web:t1", images: [], history: true, delivery: null });
});

test("an armed Revise: POST /turn carries revises {turn_id} only, it lets go at the ack; a Verify's echo is marked", async () => {
  const h = harness({ text: "shorter", revise: { turn_id: "t-v1", label: "The ticket" } });
  await h.send();
  assert.deepEqual(h.calls[0][3], { clientId: "web:t1", images: [], history: true, delivery: null, revises: { turn_id: "t-v1" } });
  assert.equal(h.revise(), null);
  assert.equal(h.bubbles[0].el.dataset.verify, undefined);
  const checked = harness({ verify: { turn_id: "t-src", quote: "q" } });
  await checked.send();
  assert.equal(checked.bubbles[0].el.dataset.verify, "1");
});

test("a refused Revise (409 revise_unavailable): its words in the history, the text and the chip kept", async () => {
  const detail = "this session's worker predates Revise turns; restart this session to use Revise";
  const h = harness({ revise: { turn_id: "t-v1", label: "x" },
                      sendTurn: async () => { throw failure("revise_unavailable", "refused", { error: "revise_unavailable", detail }); } });
  await h.send();
  assert.deepEqual(h.log.find((entry) => entry[0] === "commandBubble"), ["commandBubble", { label: null, line: "hello", text: detail, failed: true }]);
  assert.equal(h.promptEl.value, "hello");
  assert.deepEqual(h.revise(), { turn_id: "t-v1", label: "x" });
  assert.equal(h.toasts.length, 0);
});

test("a Revise turn restored before its ack: its draft is armed again with its line", async () => {
  const h = harness({ revise: { turn_id: "t-v1", label: "x" } });
  h.earlyRestores.set("e1", { origin: { client_id: "web:t1", enqueued_id: "e1" }, prompt: "hello", revises: { turn_id: "t-v1" } });
  await h.send();
  assert.equal(h.promptEl.value, "hello");
  assert.deepEqual(h.revise(), { turn_id: "t-v1" });
});

test("the start page: an idle session with the picked model and choices, then the line as a turn in it", async () => {
  const h = harness({ open: null });
  await h.send();
  assert.deepEqual(h.calls[0], ["create", { dir: "/proj", model: "qwen", preview: "hello", llm_context: undefined, thinking: "high" }]);
  assert.equal(h.calls[1][0], "turn");
  assert.equal(h.calls[1][1], "new1");
  assert.deepEqual(h.log.slice(0, 3), ["clearChoices", "created new1", "select new1"]);
});

test("the start page: a failed create is an alert; the line and the choices stay", async () => {
  const h = harness({ open: null, createIdleSession: async () => { throw new Error("no room"); } });
  await h.send();
  assert.deepEqual(h.log, [["alert", "no room"]]);
  assert.equal(h.promptEl.value, "hello");
  assert.equal(h.button.disabled, false);
});

test("the start page: a refused review file is said in the review form, not an alert", async () => {
  const refusal = Object.assign(new Error(".env can't be a review subject"), { code: "invalid_review" });
  for (const text of ["", "hello"]) {
    const h = harness({ open: null, text, reviewSubjects: [".env"], createIdleSession: async () => { throw refusal; } });
    await h.send();
    assert.deepEqual(h.log, [["reviewRefused", ".env can't be a review subject"]], text);
  }
});

test("the start page: a refused kit is said in the 🧰 list when one was picked, else an alert (config's default)", async () => {
  const refusal = Object.assign(new Error("toolkit.kits.web: bad groups"), { code: "toolkit_refused" });
  const picked = harness({ open: null, toolkitPicked: true, createIdleSession: async () => { throw refusal; } });
  await picked.send();
  assert.deepEqual(picked.log, [["toolkitRefused", "toolkit.kits.web: bad groups"]]);
  const none = harness({ open: null, createIdleSession: async () => { throw refusal; } });
  await none.send();
  assert.deepEqual(none.log, [["toolkitRefused", "toolkit.kits.web: bad groups"], ["alert", "toolkit.kits.web: bad groups"]]);
});

test("the start page's own reply is a notice; nothing is made or sent", async () => {
  assert.ok(routeComposerLine("/help", { session: false }).reply);
  const h = harness({ open: null, text: "/help" });
  await h.send();
  assert.equal(h.calls.length, 0);
  assert.equal(h.log[0][0], "notice");
  assert.equal(h.cleared(), 1);
});

// In a session the page's own reply (a terminal's /archive, /exit; a typo's
// hint) is a command bubble with the line: nothing goes to the worker.
test("in a session the page's own reply is a command bubble: /archive's words, /modle's hint; nothing is sent", async () => {
  const commands = [{ name: "/model" }, { name: "/recap" }];
  for (const [text, reply] of [["/archive", /^\/archive: use the archive button in the session bar$/],
    ["/exit", /^\/exit: close the tab to leave/], ["/modle", /^Unknown command \/modle\. Did you mean \/model\?/]]) {
    const h = harness({ text, state: { commands } });
    await h.send();
    assert.deepEqual(h.calls, [], text);
    assert.equal(h.bubbles.length, 0, text);
    const bubble = h.log.find((entry) => entry[0] === "commandBubble");
    assert.equal(bubble[1].line, text);
    assert.match(bubble[1].text, reply);
    assert.equal(h.cleared(), 1, text);
  }
  // /recap off is the worker's: a command, not a reply.
  const recap = harness({ text: "/recap off", state: { commands } });
  await recap.send();
  assert.deepEqual(recap.log, [["command", "/recap off"]]);
});

test("a fresh link's pick in flight goes first; a terminal's session sends nothing", async () => {
  let release;
  const pick = new Promise((resolve) => { release = resolve; });
  const h = harness({ pendingPick: pick });
  const sending = h.send();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(h.calls.length, 0);
  release(true);
  await sending;
  assert.equal(h.calls.length, 1);
  const tui = harness({ state: { owner: "tui" } });
  await tui.send();
  assert.equal(tui.calls.length, 0);
});

test("only the sent chips go at the ack: an image added while the send was in flight stays", async () => {
  const sent = { name: "a", file: {} };
  const later = { name: "b", file: {} };
  let h;
  h = harness({ chips: [sent], sendTurn: async () => { h.world.chips = [...h.world.chips, later]; return { enqueued_id: "e1" }; } });
  await h.send();
  assert.deepEqual(h.calls[0], ["upload", "s1", "a"]);
  assert.deepEqual(h.world.chips, [later]);
});

test("a switch while the send is in flight: the ack's follow and restore stay with the session it went to", async () => {
  let h;
  h = harness({ sendTurn: async () => { h.world.selected = "s2"; return { enqueued_id: "e1" }; } });
  h.earlyRestores.set("e1", { origin: { client_id: "web:t1", enqueued_id: "e1" }, prompt: "hello" });
  await h.send();
  assert.ok(!h.log.includes("follow"));
  assert.ok(!h.log.includes("openForVisit"));
  // The restored line still comes back into the (shared) composer.
  assert.equal(h.promptEl.value, "hello");
});

test("a restored line put back after a switch is a draft of the session it went to (continue's draft origin)", async () => {
  let h;
  h = harness({ sendTurn: async () => { h.world.selected = "s2"; h.promptEl.value = ""; return { enqueued_id: "e1" }; } });
  h.earlyRestores.set("e1", { origin: { client_id: "web:t1", enqueued_id: "e1" }, prompt: "hello" });
  await h.send();
  assert.equal(h.promptEl.value, "hello");
  assert.ok(h.log.includes("noteDraft s1"));
});

test("a turn restored before its ack: its line back in the composer, which opens", async () => {
  const h = harness();
  h.earlyRestores.set("e1", { origin: { client_id: "web:t1", enqueued_id: "e1" }, prompt: "hello" });
  await h.send();
  assert.equal(h.promptEl.value, "hello");
  assert.ok(h.log.includes("openForVisit"));
  assert.equal(h.earlyRestores.size, 0);
});

test("a Verify turn restored before its ack: its claim is armed again with its line", async () => {
  const anchor = { turn_id: "t-src", quote: "the cache key" };
  const h = harness({ verify: anchor });
  h.earlyRestores.set("e1", { origin: { client_id: "web:t1", enqueued_id: "e1" }, prompt: "hello", verify: anchor });
  await h.send();
  assert.equal(h.promptEl.value, "hello");
  assert.deepEqual(h.verify(), anchor);
});

test("an ack naming a command: the echo goes, the composer is cleared, no prompt bubble stays", async () => {
  const h = harness({ sendTurn: async () => ({ command_id: "c1" }) });
  await h.send();
  assert.equal(h.bubbles[0].el.parentNode, null);
  assert.equal(h.cleared(), 1);
  assert.deepEqual(h.log, ["follow", "focus"]);
});

test("errors: a terminal took the session; elsewhere it is a toast", async () => {
  const h = harness({ sendTurn: async () => { throw failure("owned_by_tui"); } });
  h.earlyRestores.set("old", {});
  await h.send();
  assert.equal(h.bubbles[0].el.parentNode, null);
  assert.equal(h.earlyRestores.size, 0);
  assert.equal(h.world.state.owner, "tui");
  assert.ok(h.log.includes("composerMode"));
  assert.ok(h.log.includes("infoBar"), "the bar follows the owner too (its continue and stop, the title's ✎)");
  assert.equal(h.button.disabled, true);
  assert.equal(h.promptEl.value, "hello");
  let away;
  away = harness({ sendTurn: async () => { away.world.selected = "s2"; throw failure("owned_by_tui"); } });
  await away.send();
  assert.equal(away.toasts.length, 1);
  assert.match(away.toasts[0].text, /send to s1/);
  assert.equal(away.toasts[0].options.sticky, true);
});

test("errors: a deleted session goes to the start page; a /queue to a worker that can't queue is a failed bubble", async () => {
  const gone = harness({ sendTurn: async () => { throw failure("not_found"); } });
  await gone.send();
  assert.ok(gone.log.includes("gone s1 not_found"));
  const queue = harness({ sendTurn: async () => { throw failure("delivery_unavailable", "x", { detail: "can't queue" }); } });
  await queue.send();
  assert.deepEqual(queue.log.find((l) => l[0] === "commandBubble"),
                   ["commandBubble", { label: null, line: "hello", text: "can't queue", failed: true }]);
});

test("errors: anything else is a sticky toast; the line stays in the composer", async () => {
  const h = harness({ sendTurn: async () => { throw failure("boom", "server down"); } });
  await h.send();
  assert.equal(h.toasts.length, 1);
  assert.match(h.toasts[0].text, /server down/);
  assert.equal(h.promptEl.value, "hello");
});

test("into a running turn the echo says its delivery; a line with images waits for the turn's end", async () => {
  const h = harness({ running: true });
  await h.send({ delivery: "cut" });
  assert.equal(h.bubbles[0].opts.delivery, "cut");
  assert.equal(h.calls[0][3].delivery, "cut");
  const img = harness({ running: true, chips: [{ name: "a", file: {} }] });
  await img.send();
  assert.equal(img.bubbles[0].opts.delivery, "queue");
});
