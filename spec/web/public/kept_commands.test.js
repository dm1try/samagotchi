import test from "node:test";
import assert from "node:assert/strict";
import { commandAnchor, anchorInsertIndex, keepsCommandBubble } from "../../../lib/samagotchi/web/public/kept_commands.js";

test("commandAnchor counts the prompts and saved shell commands before a bubble", () => {
  const kinds = ["user", "other", "other", "shell", "user", "other", "other"];
  assert.deepEqual(commandAnchor(kinds, 0), { users: 0, shells: 0 });
  assert.deepEqual(commandAnchor(kinds, 3), { users: 1, shells: 0 });
  assert.deepEqual(commandAnchor(kinds, 6), { users: 2, shells: 1 });
});

test("anchorInsertIndex puts a bubble after its turn: before the next prompt or shell command", () => {
  // turn 1, then /help, then !ls ran: the redrawn history ends with !ls's saved bubble.
  const redrawn = ["user", "other", "other", "shell"];
  assert.equal(anchorInsertIndex(redrawn, { users: 1, shells: 0 }), 3);
  // after !ls too: the end
  assert.equal(anchorInsertIndex(redrawn, { users: 1, shells: 1 }), 4);
  // before any turn: the top
  assert.equal(anchorInsertIndex(redrawn, { users: 0, shells: 0 }), 0);
  // between two turns: before the second prompt
  assert.equal(anchorInsertIndex(["user", "other", "user", "other"], { users: 1, shells: 0 }), 2);
});

test("anchorInsertIndex: an anchor past a shorter history (a !rollback) goes at the end", () => {
  assert.equal(anchorInsertIndex(["user", "other"], { users: 3, shells: 0 }), 2);
  assert.equal(anchorInsertIndex([], { users: 1, shells: 2 }), 0);
});

test("a round trip keeps the order of the redrawn history and the kept bubbles", () => {
  // live: [user, output, /help, !ls(live), /model]; !ls's bubble is redrawn from its saved message
  const live = ["user", "other", "cmd", "shell", "cmd"];
  const anchors = [2, 4].map((i) => commandAnchor(live, i));
  const redrawn = ["user", "other", "shell"];
  const out = redrawn.slice();
  anchors.forEach((anchor, n) => out.splice(anchorInsertIndex(out, anchor), 0, `cmd${n}`));
  assert.deepEqual(out, ["user", "other", "cmd0", "shell", "cmd1"]);
});

test("keepsCommandBubble: a !cmd's bubble is the saved history's, every other command's is kept", () => {
  assert.equal(keepsCommandBubble("!ls -la"), false);
  assert.equal(keepsCommandBubble("! echo hi"), false);
  for (const line of ["!rollback", "!rollback 2", "/help", "/model x", "/llm-context forget", "(/queue isn't available in the web yet)", ""]) {
    assert.equal(keepsCommandBubble(line), true, line);
  }
});
