// The prompt-writes lint rule (eslint.config.js "samagotchi/prompt-writes"):
// only drafts.js writes the message box's value (and only it, through the
// mount, the chips: app.js's composer.setChips). Linted through the whole
// config by file path, as `npm run lint` lints: a later block's
// no-restricted-syntax replaces an earlier one's, so the session-writes
// modules carry both lists in one block.
import test from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ESLint } from "eslint";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const PUBLIC = "lib/samagotchi/web/public";
const eslint = new ESLint({ cwd: ROOT });

const PROMPT = /^The message box and its chips are the drafts'/;
const SESSION = /^The open session's state is written through the store/;

// The flagged lines' text, with which rule's words, for +code+ linted as +file+.
async function flagged(code, file) {
  const [result] = await eslint.lintText(code, { filePath: join(ROOT, PUBLIC, file) });
  return result.messages.filter((m) => m.ruleId === "no-restricted-syntax").map((m) => {
    const kind = PROMPT.test(m.message) ? "prompt" : SESSION.test(m.message) ? "session" : m.message;
    return [code.split("\n")[m.line - 1].trim(), kind];
  });
}

const WRITES = [
  "promptEl.value = text;",
  "prompt.value = pick.text;",
  "promptEl.value += more;",
  "composer.el.value = '';",
];
// Other boxes' values (model_picker.js, session_rename.js), reads, and the drafts' own calls.
const FINE = [
  "input.value = name;",
  "search.value = '';",
  "attachInput.value = '';",
  "const typed = promptEl.value;",
  "drafts.setText(key, text);",
  "composer.putChips(key, list);",
];
const declared = "/* global promptEl, prompt, pick, text, more, composer, input, name, search, attachInput, drafts, key, list, current, list2, view */\n";

test("a write of the box's value is flagged in any module but drafts.js", async () => {
  for (const file of ["command_list.js", "composer_mount.js", "send_turn.js", "app.js"]) {
    const got = await flagged(declared + WRITES.join("\n"), file);
    assert.deepEqual(got, WRITES.map((line) => [line, "prompt"]), file);
  }
  assert.deepEqual(await flagged(declared + WRITES.join("\n"), "drafts.js"), []);
});

test("other boxes' values, reads and the drafts' calls are left alone", async () => {
  for (const file of ["model_picker.js", "send_turn.js", "app.js"]) {
    assert.deepEqual(await flagged(declared + FINE.join("\n"), file), [], file);
  }
});

test("a session-writes module keeps both rules: its state writes and the box's", async () => {
  const code = `${declared}current.owner = 'tui';\npromptEl.value = text;`;
  for (const file of ["send_turn.js", "session_view.js", "app.js"]) {
    assert.deepEqual(await flagged(code, file), [["current.owner = 'tui';", "session"], ["promptEl.value = text;", "prompt"]], file);
  }
  // Elsewhere `current` is another thing: only the box's rule.
  assert.deepEqual(await flagged(code, "turn_model.js"), [["promptEl.value = text;", "prompt"]]);
});

test("the mount's setChips is the drafts' in app.js; another module's own setChips is left alone", async () => {
  const code = `${declared}composer.setChips(list);\nview.setChips(list2);`;
  assert.deepEqual(await flagged(code, "app.js"), [["composer.setChips(list);", "prompt"]]);
  assert.deepEqual(await flagged(code, "stream_handlers.js"), []);
});

test("every real module of the page passes", async () => {
  const results = await eslint.lintFiles([`${PUBLIC}/**/*.js`]);
  const hits = results.flatMap((r) => r.messages.filter((m) => PROMPT.test(m.message)).map((m) => `${r.filePath.slice(ROOT.length + 1)}:${m.line}`));
  assert.deepEqual(hits, []);
});
