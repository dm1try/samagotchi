// The stage's cross-check (card_kinds.js warnDiffers; stage_asking.js
// reconcileWaiting's drift check, switched on for each test): a test file
// that calls this fails any of its tests during which the page warned
// "stage: waiting …". console.warn
// is wrapped once for the process (npm test runs every file in one) and still
// prints. Top-level hooks: under npm test's one process they apply to the
// files loaded after this one too, which keep the check as well.
import { afterEach, beforeEach } from "node:test";
import assert from "node:assert/strict";

const seen = [];
if (!console.warn.chiWaitingSpy) {
  const warn = console.warn;
  const spy = (...args) => {
    if (String(args[0]).startsWith("stage: waiting")) seen.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
    return warn.apply(console, args);
  };
  spy.chiWaitingSpy = true;
  console.warn = spy;
}

// The "stage: waiting …" warnings since the last take (a test that expects
// one reads it here, so the after-each check doesn't fail it).
export const takeWaitingWarnings = () => seen.splice(0);

// The drift check on (<body data-stage-check="1">) for each test of the file.
export function failOnWaitingWarnings() {
  beforeEach(() => {
    if (globalThis.document?.body) document.body.dataset.stageCheck = "1";
  });
  afterEach(() => {
    if (globalThis.document?.body) delete document.body.dataset.stageCheck;
    assert.deepEqual(seen.splice(0), [], "the stage's waiting cards as data agree with the cards drawn");
  });
}
