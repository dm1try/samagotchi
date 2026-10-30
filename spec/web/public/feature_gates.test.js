import test from "node:test";
import assert from "node:assert/strict";
import { createFeatureGates } from "../../../lib/samagotchi/web/public/feature_gates.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

// The Verify gate as app.js has it: a live bridge with the feature.
const verifyOff = (cur) => !(cur.bridgeUp === true && cur.workerFeatures.includes("verify"));
const FIELDS = {
  workerFeatures: { redraws: ["featureGates", "infoBar"] },
  bridgeUp: { redraws: ["featureGates", "infoBar"] },
  owner: { redraws: ["composer", "infoBar"] },
};
const EMPTY = { workerFeatures: [], bridgeUp: false, owner: null };

// A store with the gates registered as app.js registers them; +fired+
// records each gate redraw.
function page() {
  const fired = [];
  const store = createSessionStore({ initial: { ...EMPTY }, fields: FIELDS });
  const gates = createFeatureGates([
    { name: "verify", unavailable: verifyOff, redraw: () => fired.push("verify") },
    { name: "other", unavailable: (cur) => !cur.workerFeatures.includes("other"), redraw: () => fired.push("other") },
  ]);
  gates.prime(store.current);
  store.on("featureGates", () => gates.check(store.current));
  return { store, gates, fired };
}

test("a gate redraws only when its answer flips", () => {
  const { store, fired } = page();
  store.update({ current: { owner: "worker" } });
  assert.deepEqual(fired, [], "a field it doesn't read");
  store.update({ current: { workerFeatures: ["delivery"] } });
  assert.deepEqual(fired, [], "read, but no gate flipped");
  store.update({ current: { workerFeatures: ["verify"], bridgeUp: true } });
  assert.deepEqual(fired.splice(0), ["verify"]);
  store.update({ current: { workerFeatures: ["verify", "delivery"] } });
  assert.deepEqual(fired, [], "still available");
});

test("the worker going flips it back: unavailable", () => {
  const { store, fired } = page();
  store.update({ current: { workerFeatures: ["verify"], bridgeUp: true } });
  fired.splice(0);
  store.update({ current: { owner: null, bridgeUp: false } });
  assert.deepEqual(fired, ["verify"]);
});

test("each gate flips on its own", () => {
  const { store, fired } = page();
  store.update({ current: { workerFeatures: ["other"] } });
  assert.deepEqual(fired, ["other"]);
});

test("prime takes the answer without redrawing: a switch or a full load in a batch fires nothing", () => {
  const { store, gates, fired } = page();
  store.update({ current: { workerFeatures: ["verify"], bridgeUp: true } });
  fired.splice(0);
  // forgetSession: a new object, primed in the same batch.
  store.batch(() => {
    store.replaceCurrent({ ...EMPTY });
    gates.prime(store.current);
  });
  assert.deepEqual(fired, []);
  // renderSessionView: the payload's fields, primed in the same batch.
  store.batch(() => {
    store.update({ current: { workerFeatures: ["verify", "other"], bridgeUp: true } });
    gates.prime(store.current);
  });
  assert.deepEqual(fired, []);
  // A later write flips from the primed answer.
  store.update({ current: { bridgeUp: false } });
  assert.deepEqual(fired, ["verify"]);
});
