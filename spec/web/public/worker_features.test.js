// The one rule behind the worker-side feature gates (verify_preset.js,
// revise_stack.js): only a live worker whose features lack it predates it.
import test from "node:test";
import assert from "node:assert/strict";
import { workerPredates } from "../../../lib/samagotchi/web/public/worker_features.js";
import { verifyWorkerUnavailable } from "../../../lib/samagotchi/web/public/verify_preset.js";

test("workerPredates: a live worker without the feature only", () => {
  assert.equal(workerPredates(["verify"], true, "revise"), true);
  assert.equal(workerPredates(["verify", "revise"], true, "revise"), false, "the worker has it");
  assert.equal(workerPredates([], false, "verify"), false, "a sleeping worker wakes as a new one");
  assert.equal(workerPredates(["verify"], false, "verify"), false, "down, whatever it last had");
  assert.equal(workerPredates(null, true, "verify"), false, "no features to read");
  assert.equal(workerPredates(undefined, true, "verify"), false);
  assert.equal(workerPredates(["verify"], undefined, "verify"), false, "not known to be up");
});

test("Verify's gate is this rule with its own feature name", () => {
  for (const [features, up] of [["verify", true], ["verify,revise", true], ["", false], ["", true], [null, true]]) {
    const list = features ? features.split(",") : features;
    assert.equal(verifyWorkerUnavailable(list, up), workerPredates(list, up, "verify"), `${features} / ${up}`);
  }
});
