// One rule for the worker-side feature gates: a worker that is up and whose
// features lack +feature+ predates it (chi web would answer 409
// <feature>_unavailable), so the page says so instead of offering the action.
// A worker that isn't up isn't asked: the send wakes a new one that has it.
// Used by Verify's gate (verify_preset.js) and Revise's (revise_stack.js).
//
// A new module: the page's modules are cached at unversioned URLs, and a new
// export of an old one (docs/internals/web-frontend.md) leaves a cached copy
// without it.

// @return [bool] true only for a live worker without the feature.
export function workerPredates(workerFeatures, bridgeUp, feature) {
  return bridgeUp === true && Array.isArray(workerFeatures) && !workerFeatures.includes(feature);
}
