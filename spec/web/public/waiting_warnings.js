// The stage's cross-check (card_kinds.js warnDiffers: the data and the
// node disagree): a test file that calls this fails any of its tests during
// which the page warned "stage: waiting …". console.warn
// is wrapped once for the process (npm test runs every file in one) and still
// prints. Top-level hooks: under npm test's one process they apply to the
// files loaded after this one too, which keep the check as well.
import { afterEach } from "node:test";
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

// Each test of the file ends with no such warning.
export function failOnWaitingWarnings() {
  afterEach(() => {
    assert.deepEqual(seen.splice(0), [], "the stage's waiting cards as data agree with the cards drawn");
  });
}
