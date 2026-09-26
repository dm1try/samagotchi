import test from "node:test";
import assert from "node:assert/strict";
import { commandMatches, commandRow, moveSelection, pickCommand } from "../../../lib/samagotchi/web/public/command_complete.js";

const commands = [
  { name: "!rollback", description: "roll back", anytime: false, local: false, source: "core" },
  { name: "!", description: "shell", anytime: false, local: false, source: "core" },
  { name: "/model", description: "show or switch the model", anytime: false, local: false, source: "core" },
  { name: "/models", description: "list the models", anytime: false, local: false, source: "core" },
  { name: "/help", description: "list the commands", anytime: true, local: false, source: "core" },
  { name: "/hello-slow", description: "greet later", anytime: true, local: false, source: "sample-plugin" },
  { name: "/hello", description: "greet", anytime: false, local: false, source: "sample-plugin" },
  { name: "/stats", description: "stats", anytime: false, local: true, uis: null, source: "core" },
];

test("commandMatches offers the session's slash commands starting with what is typed, by name", () => {
  assert.deepEqual(commandMatches(commands, "/").map((c) => c.name), ["/hello", "/hello-slow", "/help", "/model", "/models"]);
  assert.deepEqual(commandMatches(commands, "/he").map((c) => c.name), ["/hello", "/hello-slow", "/help"]);
  assert.deepEqual(commandMatches(commands, "/HEL").map((c) => c.name), ["/hello", "/hello-slow", "/help"]);
  assert.deepEqual(commandMatches(commands, "/model").map((c) => c.name), ["/model", "/models"]);
});

test("commandMatches offers nothing once arguments start, for other text, a terminal-only command or no list", () => {
  assert.deepEqual(commandMatches(commands, "/hello "), []);
  assert.deepEqual(commandMatches(commands, "/hello\nx"), []);
  assert.deepEqual(commandMatches(commands, "hello"), []);
  assert.deepEqual(commandMatches(commands, "!"), []);
  assert.deepEqual(commandMatches(commands, " /he"), []);
  assert.deepEqual(commandMatches(commands, "/st"), []);
  assert.deepEqual(commandMatches(commands, "/zz"), []);
  assert.deepEqual(commandMatches(undefined, "/"), []);
  assert.deepEqual(commandMatches([null, { description: "no name" }], "/"), []);
});

test("pickCommand completes the name with a space; Enter on the full name sends it", () => {
  assert.deepEqual(pickCommand("/hello", "/he"), { text: "/hello ", send: false });
  assert.deepEqual(pickCommand("/hello", "/he", { enter: true }), { text: "/hello ", send: false });
  assert.deepEqual(pickCommand("/help", "/help", { enter: true }), { text: "/help", send: true });
  // Tab on the full name only adds the space.
  assert.deepEqual(pickCommand("/help", "/help"), { text: "/help ", send: false });
});

test("moveSelection wraps both ways, and there is none in an empty list", () => {
  assert.equal(moveSelection(0, 3, 1), 1);
  assert.equal(moveSelection(2, 3, 1), 0);
  assert.equal(moveSelection(0, 3, -1), 2);
  assert.equal(moveSelection(-1, 3, 1), 0);
  assert.equal(moveSelection(0, 0, 1), -1);
});

test("commandRow notes a bundle's source and an anytime command", () => {
  assert.deepEqual(commandRow(commands[6]), { name: "/hello", description: "greet", note: "sample-plugin" });
  assert.deepEqual(commandRow(commands[5]), { name: "/hello-slow", description: "greet later", note: "sample-plugin · mid-turn too" });
  assert.deepEqual(commandRow(commands[2]), { name: "/model", description: "show or switch the model", note: "" });
  assert.deepEqual(commandRow({ name: "/x" }), { name: "/x", description: "", note: "" });
});
