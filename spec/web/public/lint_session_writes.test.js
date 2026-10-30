// The session-writes lint rule (eslint.config.js "samagotchi/session-writes")
// over a sample with every form it must catch and the ones it must leave.
import test from "node:test";
import assert from "node:assert/strict";
import { Linter } from "eslint";
import config from "../../../eslint.config.js";

const block = config.find((b) => b.name === "samagotchi/session-writes");

function flaggedLines(code) {
  const linter = new Linter({ configType: "flat" });
  const messages = linter.verify(code, [{
    languageOptions: { ecmaVersion: "latest", sourceType: "module" },
    rules: block.rules,
  }]);
  return messages.map((m) => {
    assert.equal(m.ruleId, "no-restricted-syntax", m.message);
    return code.split("\n")[m.line - 1].trim();
  });
}

test("every in-place write of the session's state is flagged", () => {
  const writes = [
    "current.owner = 'tui';",
    "current.owner ??= null;",
    "current.timing.side = side;",
    "state().model = name;",
    "state().timing.side = side;",
    "store.current.owner = 'tui';",
    "store.current.timing.side = side;",
    "current.ctxPct += 1;",
    "current.count++;",
    "delete current.owner;",
    "Object.assign(current, fields);",
    "Object.assign(store.current, fields);",
  ];
  assert.deepEqual(flaggedLines(writes.join("\n")), writes);
});

test("the store's writes, reads and other objects' fields are left alone", () => {
  const fine = [
    "store.update({ current: { owner: 'tui' } });",
    "store.setStatus('stopped', 'stop');",
    "const owner = store.current.owner;",
    "const pct = state().ctxPct;",
    "gen.iteration = iteration;",
    "Object.assign(versions, next);",
    "liveTurn.running = true;",
  ];
  assert.deepEqual(flaggedLines(fine.join("\n")), []);
});

test("the rule is scoped to the session's writers, not every module", () => {
  assert.ok(block.files.includes("lib/samagotchi/web/public/app.js"));
  assert.equal(block.files.length, 6);
  assert.ok(!block.files.some((f) => f.endsWith("turn_model.js")), "genFor's local `current` is a gen");
});
