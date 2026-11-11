import test from "node:test";
import assert from "node:assert/strict";
import { stateOfParams, stateWord } from "../../../lib/samagotchi/web/public/objectives_state.js";

test("a state's words: claims done, blocked, nothing for progress or one unknown", () => {
  assert.equal(stateWord("done"), "claims done");
  assert.equal(stateWord("blocked"), "blocked");
  assert.equal(stateWord("progress"), null);
  assert.equal(stateWord(undefined), null);
  assert.equal(stateWord("toString"), null);
});

test("a row's state is read from its params, before the note only", () => {
  assert.equal(stateOfParams('id="O2" state="done" note="green"'), "done");
  assert.equal(stateOfParams('id="O2" state="blocked" note="stuck" evidence="e"'), "blocked");
  assert.equal(stateOfParams('id="O2" note="say state=\\"done\\" here"'), null);
  assert.equal(stateOfParams('change="done" id="O2" note="n"'), null);
  assert.equal(stateOfParams(undefined), null);
});
