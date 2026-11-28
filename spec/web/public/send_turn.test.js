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
import { sendTurn as sendTurnRequest } from "../../../lib/samagotchi/web/public/data.js";
import { createDrafts } from "../../../lib/samagotchi/web/public/drafts.js";

if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

function failure(code, message = "boom", body = null) {
  return Object.assign(new Error(message), { status: 409, code, body });
}

// +sendTurn+ / +createIdleSession+: the data.js stand-ins (each call logged).
// +bag+ "drafts": the composer as app.js passes it (drafts.js' calls, by the
// draft's key; each logged in +drafts+); "old": an older cached app.js's
// (el, chips(), setChips(list), clear(), noteDraft: the one box).
function harness({ open = "s1", text = "hello", chips = [], state = {}, running = false, pendingPick = null,
                   verify = null, revise = null, toolkitPicked = false, sendTurn = async () => ({ enqueued_id: "e1" }),
                   createIdleSession = async () => ({ id: "new1" }), commands = true, bag = "drafts" } = {}) {
  // world.state reads the page's session store; setting it is a session
  // switch (forgetSession's replaceCurrent).
  const store = createSessionStore({ initial: { owner: "worker", commands: [], firstPreview: "first", ...state } });
  // The page's drafts (drafts.js) over a textarea and a stand-in mount: the
  // box and +world.chips+ are the draft on view; a switch (world.selected =)
  // swaps them as forgetSession does. The old bag has no drafts: one box.
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (key === "chi_start_draft" || key?.startsWith("chi_composer_draft:")) localStorage.removeItem(key);
  }
  const promptEl = document.createElement("textarea");
  let mountChips = [];
  const mount = { chips: () => mountChips, setChips: (list) => { mountChips = list; } };
  let selected = open;
  const realDrafts = bag === "old" ? null : createDrafts({ promptEl, view: mount, shownKey: () => selected ?? "" });
  realDrafts?.show(open ?? "");
  promptEl.value = text;
  mountChips = chips;
  const world = {
    get selected() { return selected; },
    set selected(id) { selected = id; realDrafts?.show(id ?? ""); },
    get chips() { return mountChips; },
    set chips(list) { mountChips = list; },
    get state() { return store.current; },
    set state(fields) { store.replaceCurrent(fields); },
  };
  const log = [];
  const calls = [];
  const toasts = [];
  const bubbles = [];
  const historyEl = document.createElement("div");
  const button = { disabled: false };
  const sentIds = new Set();
  const earlyRestores = new Map();
  // The page's redraws, registered as app.js registers them.
  store.on("composer", () => log.push("composerMode"));
  store.on("infoBar", () => log.push("infoBar"));
  let cleared = 0;
  const drafts = [];
  // The drafts' moves and the selects, in the order they happened.
  const seq = [];
  const oldBag = {
    el: promptEl,
    button,
    chips: () => world.chips,
    setChips: (list) => { world.chips = list; },
    fit: () => {},
    clear: () => { cleared += 1; promptEl.value = ""; },
    openForVisit: () => log.push("openForVisit"),
    focus: () => log.push("focus"),
    noteDraft: (id) => log.push(`noteDraft ${id}`),
  };
  // The real drafts by key, each call logged.
  const draftsBag = realDrafts && {
    ...oldBag,
    el: undefined,
    setChips: undefined,
    noteDraft: undefined,
    text: (key) => { drafts.push(["text", key]); return realDrafts.text(key); },
    chips: (key) => { drafts.push(["chips", key]); return realDrafts.chips(key); },
    setText: (key, value) => { drafts.push(["setText", key, value]); realDrafts.setText(key, value); },
    putChips: (key, list) => { drafts.push(["putChips", key, list.map((c) => c.name)]); realDrafts.putChips(key, list); },
    clear: (key) => { drafts.push(["clear", key]); cleared += 1; realDrafts.clear(key); },
    move: (from, to) => { drafts.push(["move", from, to]); seq.push(`move ${from} → ${to}`); realDrafts.move(from, to); },
    sending: (key, line) => { drafts.push(["sending", key, line]); realDrafts.sending(key, line); },
    settle: (key, line) => { drafts.push(["settle", key, line]); realDrafts.settle(key, line); },
  };
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
      toolkitRefused: (message) => { log.push(["toolkitRefused", message]); return toolkitPicked; },
    },
    takeDelivery: () => null,
    composer: bag === "old" ? oldBag : draftsBag,
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
    select: async (id) => { log.push(`select ${id}`); seq.push(`select ${id}`); world.selected = id; world.state = { owner: null, commands: [] }; },
    showNotice: (text) => log.push(["notice", text]),
    followWokenWorker: () => log.push("follow"),
    refreshHistory: () => log.push("refreshHistory"),
    leaveGoneSession: (id, why) => log.push(`gone ${id} ${why}`),
    // +commands+ false: a viewer without session commands (viewer.js), as app.js passes it.
    runCommand: commands ? (command) => log.push(["command", command]) : null,
    toast: (text, action, options) => toasts.push({ text, options }),
    alert: (text) => log.push(["alert", text]),
  });
  // The keys the drafts were written by (setText, putChips, clear, move).
  const writes = () => drafts.filter(([op]) => !["text", "chips", "sending", "settle"].includes(op));
  return { send: sendTurnApi.send, world, log, calls, toasts, bubbles, promptEl, button, sentIds, earlyRestores,
           cleared: () => cleared, verify: () => verify, revise: () => revise, drafts, writes, realDrafts, seq };
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

test("a Revise or a Verify into a running turn: its echo says it queues (the worker holds it for the turn's end)", async () => {
  const revise = harness({ running: true, revise: { turn_id: "t-v1", label: "x" } });
  await revise.send();
  assert.equal(revise.bubbles[0].opts.delivery, "queue");
  const verify = harness({ running: true, verify: { turn_id: "t-src", quote: "q" } });
  await verify.send();
  assert.equal(verify.bubbles[0].opts.delivery, "queue");
  const plain = harness({ running: true });
  await plain.send();
  assert.equal(plain.bubbles[0].opts.delivery, "next_step");
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

test("a participant's refused Revise (403 revise_not_own, 409 revise_overtaken): the server's words, the text and the chip kept", async () => {
  for (const code of ["revise_not_own", "revise_overtaken"]) {
    const detail = `the server's words for ${code}`;
    const h = harness({ revise: { turn_id: "t-v1", label: "x" },
                        sendTurn: async () => { throw failure(code, "refused", { error: code, detail }); } });
    await h.send();
    assert.deepEqual(h.log.find((entry) => entry[0] === "commandBubble"), ["commandBubble", { label: null, line: "hello", text: detail, failed: true }]);
    assert.equal(h.promptEl.value, "hello");
    assert.deepEqual(h.revise(), { turn_id: "t-v1", label: "x" });
    assert.equal(h.toasts.length, 0);
  }
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
  // The restored line comes back into the draft of the session it went to, not the one on view.
  assert.equal(h.realDrafts.text("s1"), "hello");
  assert.equal(h.promptEl.value, "");
});

test("a switch while the send is in flight: the ack empties the draft it went from; the draft typed in the session opened stays", async () => {
  let h;
  h = harness({ chips: [{ name: "a", file: {} }], sendTurn: async () => {
    h.world.selected = "s2";
    h.promptEl.value = "typed in s2";
    h.realDrafts.syncFromView();
    return { enqueued_id: "e1" };
  } });
  await h.send();
  assert.equal(h.promptEl.value, "typed in s2");
  assert.equal(h.realDrafts.text("s1"), "");
  assert.deepEqual(h.realDrafts.chips("s1"), []);
  assert.deepEqual(h.writes(), [["setText", "s1", ""], ["putChips", "s1", []]]);
  h.world.selected = "s1";
  assert.equal(h.promptEl.value, "");
});

test("a switch during the image upload: what follows is the draft it went from too", async () => {
  let h;
  h = harness({ chips: [{ name: "a", file: {} }] });
  const upload = h.calls;
  h.world.selected = "s1";
  const sending = h.send();
  h.world.selected = "s2";
  await sending;
  assert.deepEqual(upload[0], ["upload", "s1", "a"]);
  assert.equal(h.calls.find((c) => c[0] === "turn")[1], "s1");
  assert.equal(h.realDrafts.text("s1"), "");
});

test("an ack naming a command after a switch clears the draft it went from, not the one on view", async () => {
  let h;
  h = harness({ sendTurn: async () => { h.world.selected = "s2"; h.promptEl.value = "mine"; return { command_id: "c1" }; } });
  await h.send();
  assert.equal(h.realDrafts.text("s1"), "");
  assert.equal(h.promptEl.value, "mine");
});

test("the start page: a made session takes the start page's draft, chips too, before the page opens it", async () => {
  const chip = { name: "a", file: {} };
  const h = harness({ open: null, chips: [chip] });
  await h.send();
  assert.deepEqual(h.writes()[0], ["move", "", "new1"]);
  assert.deepEqual(h.seq, ["move  → new1", "select new1"], "the draft moves before the page opens the session");
  assert.deepEqual(h.calls.map((c) => c.slice(0, 3)), [["create", h.calls[0][1]], ["upload", "new1", "a"], ["turn", "new1", "hello"]].map((c) => c.slice(0, 3)));
  assert.equal(h.realDrafts.text(""), "");
  assert.equal(h.realDrafts.text("new1"), "");
  assert.deepEqual(h.realDrafts.chips("new1"), []);
});

test("the start page: a failed create keeps its draft on the start page", async () => {
  const h = harness({ open: null, createIdleSession: async () => { throw new Error("no room"); } });
  await h.send();
  assert.equal(h.realDrafts.text(""), "hello");
  assert.ok(!h.drafts.some(([op]) => op === "move"));
});

test("the line in flight: the saved copy leaves it out until the ack; a failure settles it back", async () => {
  let h;
  let savedMidSend;
  h = harness({ sendTurn: async () => { savedMidSend = localStorage.getItem("chi_composer_draft:s1"); return { enqueued_id: "e1" }; } });
  h.realDrafts.syncFromView();
  assert.equal(localStorage.getItem("chi_composer_draft:s1"), "hello");
  await h.send();
  assert.ok(savedMidSend === null, "a reload right after Send brings back no line already sent");
  assert.ok(localStorage.getItem("chi_composer_draft:s1") === null);
  const failing = harness({ sendTurn: async () => { throw new Error("down"); } });
  failing.realDrafts.syncFromView();
  await failing.send();
  assert.equal(localStorage.getItem("chi_composer_draft:s1"), "hello", "the line not sent is the saved draft again");
  assert.deepEqual(failing.drafts.filter(([op]) => op === "sending" || op === "settle").map((c) => c[0]).slice(0, 2), ["sending", "settle"]);
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
  assert.ok(h.bubbles[0].el.parentNode === null);
  assert.equal(h.cleared(), 1);
  assert.deepEqual(h.log, ["follow", "focus"]);
});

test("errors: a terminal took the session; elsewhere it is a toast", async () => {
  const h = harness({ sendTurn: async () => { throw failure("owned_by_tui"); } });
  h.earlyRestores.set("old", {});
  await h.send();
  assert.ok(h.bubbles[0].el.parentNode === null);
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

// An unattended update restarts chi web under an open page: for a few seconds a request fails (the connection
// is refused, or a proxy answers its bare 502). The page keeps its draft; a Send then must fail where the owner
// sees it, with the text still in the composer so the same Send works once chi web is back.
test("a Send while chi web restarts fails visibly (a refused connection, a proxy's 502) and keeps the text; the retry works", async () => {
  for (const down of [
    () => Promise.reject(new TypeError("Failed to fetch")),
    () => Promise.resolve({ ok: false, status: 502, statusText: "Bad Gateway", redirected: false, type: "basic",
                            headers: { get: () => "text/plain" }, json: async () => { throw new SyntaxError("not json"); } }),
  ]) {
    let up = false;
    const fetchImpl = async (path) => {
      if (!up) return down();
      assert.match(path, /\/api\/sessions\/s1\/turn$/);
      return { ok: true, status: 202, redirected: false, headers: { get: () => "application/json" },
               json: async () => ({ enqueued_id: "e1" }) };
    };
    const h = harness({ text: "keep me", sendTurn: (id, prompt, opts) => sendTurnRequest(id, prompt, { ...opts, fetchImpl }) });

    await h.send();

    assert.equal(h.toasts.length, 1, "one visible error");
    assert.equal(h.toasts[0].options.sticky, true);
    assert.match(h.toasts[0].text, /^Can't send: (Failed to fetch|Bad Gateway \(502\))$/);
    assert.equal(h.promptEl.value, "keep me", "the composer keeps the text");
    assert.equal(h.bubbles[0].el.isConnected, false, "the echo of a line that never went is gone");
    assert.equal(h.button.disabled, false, "Send can be pressed again");
    assert.equal(h.cleared(), 0);
    assert.equal(h.log.includes("follow"), false);

    up = true; // chi web is back
    await h.send();
    assert.equal(h.toasts.length, 1, "no second error");
    assert.equal(h.promptEl.value, "", "the retried line went, and the composer let go of it");
    assert.deepEqual(h.log.filter((entry) => entry === "follow"), ["follow"]);
  }
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

test("a viewer without session commands: a /command or ! line goes as a turn, the worker decides", async () => {
  for (const text of ["/model qwen", "!ls"]) {
    const h = harness({ text, state: { commands: [{ name: "/model" }] }, commands: false });
    await h.send();
    assert.deepEqual(h.calls, [["turn", "s1", text, { clientId: "web:t1", images: [], history: true, delivery: null }]], text);
    assert.equal(h.log.some((entry) => entry[0] === "command"), false, text);
  }
});

// ── The drafts: every read and write by the key the send started in ───────

test("drafts: the line and chips are read from the open session's draft; the ack writes that draft", async () => {
  const h = harness({ chips: [{ name: "a", file: {} }] });
  await h.send();
  assert.ok(h.drafts.some(([op, key]) => op === "text" && key === "s1"));
  assert.ok(h.drafts.filter(([op]) => op === "text" || op === "chips").every(([, key]) => key === "s1"));
  assert.deepEqual(h.writes(), [["setText", "s1", ""], ["putChips", "s1", []]]);
});

test("drafts: a switch during the send leaves the ack's writes with the session it went to", async () => {
  let h;
  h = harness({ sendTurn: async () => { h.world.selected = "s2"; return { enqueued_id: "e1" }; } });
  await h.send();
  assert.deepEqual(h.writes(), [["setText", "s1", ""], ["putChips", "s1", []]]);
});

test("drafts: an ack naming a command clears the draft it was sent from", async () => {
  let h;
  h = harness({ sendTurn: async () => { h.world.selected = "s2"; return { command_id: "c1" }; } });
  await h.send();
  assert.deepEqual(h.writes(), [["clear", "s1"]]);
});

test("drafts: the start page's reply clears the start page's draft", async () => {
  const h = harness({ open: null, text: "/help" });
  await h.send();
  assert.deepEqual(h.writes(), [["clear", ""]]);
});

// ── A mixed cache: an older cached app.js beside this send_turn.js ────────
// (drafts_mixed_cache.test.js: the other way round.)

test("an older cached app.js's composer (the one box, no drafts): the line goes, the ack empties the box, the sent chips go", async () => {
  const sent = { name: "a", file: {} };
  const h = harness({ bag: "old", chips: [sent] });
  await h.send();
  assert.equal(h.calls.at(-1)[0], "turn");
  assert.equal(h.calls.at(-1)[2], "hello");
  assert.equal(h.promptEl.value, "");
  assert.deepEqual(h.world.chips, []);
  assert.deepEqual(h.drafts, []);
});

test("an older cached app.js's composer: an ack naming a command clears the box; a reply clears it too", async () => {
  const command = harness({ bag: "old", sendTurn: async () => ({ command_id: "c1" }) });
  await command.send();
  assert.equal(command.cleared(), 1);
  const reply = harness({ bag: "old", open: null, text: "/help" });
  await reply.send();
  assert.equal(reply.cleared(), 1);
});

// r2 B4: the draft is the one open when Send was pressed, not the one open
// once a fresh link's pick (its /model) is taken.
test("a switch while the fresh link's pick is in flight: the line and chips are read from and cleared in the draft Send was pressed in", async () => {
  let release;
  const pick = new Promise((resolve) => { release = resolve; });
  const chip = { name: "a", file: {} };
  const h = harness({ pendingPick: pick, chips: [chip], text: "from s1" });
  const sending = h.send();
  h.world.selected = "s2";
  h.promptEl.value = "typed in s2";
  h.realDrafts.syncFromView();
  release(true);
  await sending;
  assert.deepEqual(h.calls.map((c) => c.slice(0, 3)), [["upload", "s1", "a"], ["turn", "s1", "from s1"]]);
  assert.equal(h.realDrafts.text("s1"), "");
  assert.deepEqual(h.realDrafts.chips("s1"), []);
  assert.equal(h.promptEl.value, "typed in s2");
  assert.ok(h.drafts.filter(([op]) => op === "text" || op === "chips").every(([, key]) => key === "s1"));
});
