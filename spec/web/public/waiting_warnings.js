// The stage's cross-check (card_kinds.js warnDiffers; stage_asking.js
// reconcileWaiting's drift check): a test file that calls this fails any of
// its tests during which the page warned "stage: waiting …". console.warn
// is wrapped once for the process (npm test runs every file in one) and still
// prints.
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

export function failOnWaitingWarnings() {
  afterEach(() => {
    assert.deepEqual(seen.splice(0), [], "the stage's waiting cards as data agree with the cards drawn");
  });
}
