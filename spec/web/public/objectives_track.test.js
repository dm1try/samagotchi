import test from "node:test";
import assert from "node:assert/strict";
import { expireTracking, TRACK_FEATURE, TRACK_LINE, trackDiffers, tracking, trackingUntil, trackText, trackWorkerUnavailable } from "../../../lib/samagotchi/web/public/objectives_track.js";

test("a reading's row says the word and the reason; no answer reads as words; none is null", () => {
  assert.equal(trackText({ reading: "no sign", reason: "nothing ran for it" }), "tracker: no sign — nothing ran for it");
  assert.equal(trackText({ reading: "no_answer", reason: "" }), "tracker: no answer");
  assert.equal(trackText(undefined), null);
  assert.equal(trackText({}), null);
});

test("it differs only from a move it disagrees with: claims done vs no sign, not a missing move nor no answer", () => {
  const item = (state, reading) => ({ move: state === null ? undefined : { state }, track: { reading } });
  assert.equal(trackDiffers(item("done", "no sign")), true);
  assert.equal(trackDiffers(item("done", "done")), false);
  assert.equal(trackDiffers(item(undefined, "progress")), false);
  assert.equal(trackDiffers(item(undefined, "done")), true);
  assert.equal(trackDiffers(item(null, "done")), false);
  assert.equal(trackDiffers(item("done", "no_answer")), false);
});

test("a running read is the view's tracking until its time, then gone", () => {
  const until = new Date(1_000).toISOString();
  const list = { items: [], tracking: { until } };
  assert.equal(tracking(list), true);
  assert.equal(trackingUntil(list), 1_000);
  assert.equal(expireTracking(list, 999), list);
  assert.deepEqual(expireTracking(list, 1_000), { items: [] });
  assert.equal(tracking({ items: [] }), false);
  assert.equal(expireTracking(null, 5), null);
});

test("the gate: only a live worker without the feature predates it; the line is the command's", () => {
  assert.equal(trackWorkerUnavailable(["verify"], true), true);
  assert.equal(trackWorkerUnavailable([TRACK_FEATURE], true), false);
  assert.equal(trackWorkerUnavailable([], false), false);
  assert.equal(TRACK_LINE, "/objectives track");
});
