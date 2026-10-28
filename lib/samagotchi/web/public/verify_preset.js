// The built-in Verify preset, after web.annotate_presets' on both pages
// (docs/internals/participants.md, Deep links): the quote, then the ask to
// check it against the code and end on a verdict line a later card can
// read. Like a preset of the config's, it fills the box and never sends.
// A preset is a text (its label) or {label, text} (annotate_bar.js). A
// module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

export const VERIFY_PRESET = Object.freeze({
  label: "Verify",
  text: "Verify this claim against the code. If this session's context doesn't settle it, say so. "
    + "End with a line `Verdict: confirmed|refuted|unclear — <one-line reason>`.",
});

export const VERIFY_UNAVAILABLE = "restart this session to use Verify";

export function verifyWorkerUnavailable(workerFeatures, bridgeUp) {
  return bridgeUp === true && Array.isArray(workerFeatures) && !workerFeatures.includes("verify");
}

// +presets+ (annotate_presets.js parsePresets) with Verify after them.
export function withVerify(presets) {
  return [...(presets || []), VERIFY_PRESET];
}
