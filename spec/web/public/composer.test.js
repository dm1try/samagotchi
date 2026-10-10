import test from "node:test";
import assert from "node:assert/strict";
import { createComposerCommands, routeComposerLine, routeSessionLine } from "../../../lib/samagotchi/web/public/composer.js";
import { QUEUE_UNAVAILABLE_WEB, STEER_CHOICE_USAGE, webLocalReply } from "../../../lib/samagotchi/web/public/commands.js";

const COMMANDS = [{ name: "/model" }, { name: "/continue" }, { name: "/help" }];
const inSession = (extra = {}) => ({ session: true, running: false, commands: COMMANDS, ...extra });
const onStart = (extra = {}) => ({ session: false, running: false, commands: [], ...extra });

// ── The routing table ────────────────────────────────────────────────────

test("a plain message is a turn, with no delivery", () => {
  assert.deepEqual(routeComposerLine("hello", inSession()), { send: "hello", delivery: null });
  assert.deepEqual(routeComposerLine("hello", inSession({ running: true })), { send: "hello", delivery: null });
});

test("an unknown /word with more after it, or a path, is a prompt", () => {
  assert.deepEqual(routeComposerLine("/foo bar", inSession()), { send: "/foo bar", delivery: null });
  assert.deepEqual(routeComposerLine("/usr/bin/env", inSession()), { send: "/usr/bin/env", delivery: null });
});

test("/cut TEXT during a turn is TEXT sent as a cut", () => {
  assert.deepEqual(routeComposerLine("/cut stop that", inSession({ running: true })), { send: "stop that", delivery: "cut" });
});

test("/cut and /queue TEXT with no turn running are TEXT as a normal turn", () => {
  assert.deepEqual(routeComposerLine("/cut now this", inSession()), { send: "now this", delivery: null });
  assert.deepEqual(routeComposerLine("/queue later", inSession()), { send: "later", delivery: null });
});

test("/queue TEXT during a turn is the page's answer, nothing sent", () => {
  assert.deepEqual(routeComposerLine("/queue later", inSession({ running: true })),
    { reply: QUEUE_UNAVAILABLE_WEB, line: "/queue later" });
});

test("a bare /cut or /queue is the usage line", () => {
  assert.deepEqual(routeComposerLine("/cut", inSession({ running: true })), { reply: STEER_CHOICE_USAGE, line: "/cut" });
  assert.deepEqual(routeComposerLine("/queue  ", onStart()), { reply: STEER_CHOICE_USAGE, line: "/queue  " });
});

test("/cut's text is routed on: a cut to a command runs the command", () => {
  assert.deepEqual(routeComposerLine("/cut /model x", inSession()), { command: "/model x" });
});

test("a session command by the session's list is a command, alone or with arguments", () => {
  assert.deepEqual(routeComposerLine("/model", inSession()), { command: "/model" });
  assert.deepEqual(routeComposerLine("/continue no, enough", inSession({ running: true })), { command: "/continue no, enough" });
});

test("a !cmd line is a command, with or without a space; a bare ! is a prompt", () => {
  assert.deepEqual(routeComposerLine("!ls -la", inSession()), { command: "!ls -la" });
  assert.deepEqual(routeComposerLine("! git status", inSession()), { command: "! git status" });
  assert.deepEqual(routeComposerLine("!", inSession()), { send: "!", delivery: null });
});

test("a terminal's own command gets the page's reply, never sent", () => {
  assert.deepEqual(routeComposerLine("/stats", inSession()), { reply: webLocalReply("/stats"), line: "/stats" });
  assert.deepEqual(routeComposerLine("/exit now", inSession()), { reply: webLocalReply("/exit"), line: "/exit now" });
});

test("a typo of a command gets the hint, not a turn", () => {
  const route = routeComposerLine("/modle", inSession());
  assert.equal(route.line, "/modle");
  assert.match(route.reply, /^Unknown command \/modle\. Did you mean \/model\?/);
});

test("with images a line is a message: no command, reply or hint", () => {
  for (const text of ["/model", "!ls", "/stats", "/modle"]) {
    assert.deepEqual(routeComposerLine(text, inSession({ images: 1 })), { send: text, delivery: null }, text);
  }
});

// ── The start page ───────────────────────────────────────────────────────

test("the start page makes a session for a message, with the text routed again in it", () => {
  assert.deepEqual(routeComposerLine("hello", onStart()), { create: true, send: "hello", delivery: null });
  assert.deepEqual(routeComposerLine("!ls", onStart()), { create: true, send: "!ls", delivery: null });
  // No turn runs on the start page: /cut TEXT is TEXT.
  assert.deepEqual(routeComposerLine("/cut hi", onStart({ running: true })), { create: true, send: "hi", delivery: null });
});

test("the start page answers its own commands and typos without a session", () => {
  assert.deepEqual(routeComposerLine("/stats", onStart()), { reply: webLocalReply("/stats"), line: "/stats" });
  assert.match(routeComposerLine("/modle", onStart()).reply, /^Unknown command \/modle\./);
  assert.deepEqual(routeComposerLine("/stats", onStart({ images: 2 })), { create: true, send: "/stats", delivery: null });
});

test("routeSessionLine routes the created session's line by its commands", () => {
  assert.deepEqual(routeSessionLine("/model", { commands: COMMANDS }), { command: "/model" });
  assert.deepEqual(routeSessionLine("!ls", { commands: [] }), { command: "!ls" });
  assert.deepEqual(routeSessionLine("hi", { commands: COMMANDS, delivery: "cut" }), { send: "hi", delivery: "cut" });
});

// ── Commands sent from the composer and from controls ────────────────────

function harness({ session = "s1", fail = null } = {}) {
  const calls = [];
  const deps = {
    session: () => session,
    clientId: "c1",
    sendCommand: async (id, line, opts) => {
      calls.push(["send", id, line, opts]);
      if (fail) throw fail;
    },
    followWokenWorker: () => calls.push(["follow"]),
    refreshHistory: () => calls.push(["refresh"]),
    failed: (line, text) => calls.push(["failed", line, text]),
    ownedByTui: () => calls.push(["tui"]),
    composer: {
      busy: () => calls.push(["busy"]),
      clear: () => calls.push(["clear"]),
      done: () => calls.push(["done"]),
    },
  };
  return { calls, commands: createComposerCommands(deps) };
}

test("send: a typed command goes out, the composer clears, the page follows the worker", async () => {
  const { calls, commands } = harness();
  await commands.send("/model x");
  assert.deepEqual(calls, [
    ["busy"], ["send", "s1", "/model x", { clientId: "c1" }], ["clear"], ["refresh"], ["follow"], ["done"],
  ]);
});

test("send: a refused command keeps the composer and shows a failed bubble", async () => {
  const { calls, commands } = harness({ fail: Object.assign(new Error("nope"), { code: "bad" }) });
  await commands.send("/model x");
  assert.deepEqual(calls.map((c) => c[0]), ["busy", "send", "failed", "done"]);
  assert.deepEqual(calls[2], ["failed", "/model x", "nope"]);
});

test("send: a session a terminal holds marks the owner, no bubble", async () => {
  const { calls, commands } = harness({ fail: Object.assign(new Error("tui"), { code: "owned_by_tui" }) });
  await commands.send("!ls");
  assert.deepEqual(calls.map((c) => c[0]), ["busy", "send", "tui", "done"]);
});

test("run: a control's command goes out and follows the worker, the composer untouched", async () => {
  const { calls, commands } = harness();
  await commands.run("/llm-context none");
  assert.deepEqual(calls, [["send", "s1", "/llm-context none", { clientId: "c1" }], ["follow"]]);
});

test("run: a failure is a failed bubble; no session, nothing sent", async () => {
  const failing = harness({ fail: new Error("down") });
  await failing.commands.run("/thinking high");
  assert.deepEqual(failing.calls.map((c) => c[0]), ["send", "failed"]);
  const none = harness({ session: null });
  await none.commands.run("/thinking high");
  assert.deepEqual(none.calls, []);
});
