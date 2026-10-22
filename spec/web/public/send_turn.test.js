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

function failure(code, message = "boom", body = null) {
  return Object.assign(new Error(message), { status: 409, code, body });
}

// +sendTurn+ / +createIdleSession+: the data.js stand-ins (each call logged).
function harness({ open = "s1", text = "hello", chips = [], state = {}, running = false, pendingPick = null,
                   sendTurn = async () => ({ enqueued_id: "e1" }), createIdleSession = async () => ({ id: "new1" }) } = {}) {
  const world = { selected: open, state: { owner: "worker", commands: [], firstPreview: "first", ...state }, chips };
  const log = [];
  const calls = [];
  const toasts = [];
  const bubbles = [];
  const historyEl = document.createElement("div");
  const promptEl = { value: text };
  const button = { disabled: false };
  const sentIds = new Set();
  const earlyRestores = new Map();
  let cleared = 0;
  const sendTurnApi = createSendTurn({
    session: () => world.selected,
    state: () => world.state,
    running: () => running,
    clientId: "web:t1",
    sentIds,
    earlyRestores,
    api: {
      createIdleSession: async (opts) => { calls.push(["create", opts]); return createIdleSession(opts); },
      uploadImage: async (id, _file, name) => { calls.push(["upload", id, name]); return { file: `${name}.png` }; },
      sendTurn: async (...args) => { calls.push(["turn", ...args]); return sendTurn(...args); },
    },
    dir: "/proj",
    startPage: {
      pendingPick: () => pendingPick,
      chosenModel: () => "qwen",
      newChoices: () => ({ llm_context: undefined, thinking: "high" }),
      clearChoices: () => log.push("clearChoices"),
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
    turnDom: {},
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
    updateInfoBar: () => {},
    updateComposerMode: () => log.push("composerMode"),
    followWokenWorker: () => log.push("follow"),
    refreshHistory: () => log.push("refreshHistory"),
    leaveGoneSession: (id, why) => log.push(`gone ${id} ${why}`),
    runCommand: (command) => log.push(["command", command]),
    toast: (text, action, options) => toasts.push({ text, options }),
    alert: (text) => log.push(["alert", text]),
  });
  return { send: sendTurnApi.send, world, log, calls, toasts, bubbles, promptEl, button, sentIds, earlyRestores,
           cleared: () => cleared };
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

test("the start page's own reply is a notice; nothing is made or sent", async () => {
  assert.ok(routeComposerLine("/help", { session: false }).reply);
  const h = harness({ open: null, text: "/help" });
  await h.send();
  assert.equal(h.calls.length, 0);
  assert.equal(h.log[0][0], "notice");
  assert.equal(h.cleared(), 1);
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
