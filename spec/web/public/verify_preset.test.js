import test from "node:test";
import assert from "node:assert/strict";
import { VERIFY_PRESET, withVerify } from "../../../lib/samagotchi/web/public/verify_preset.js";
import { presetNote } from "../../../lib/samagotchi/web/public/annotate_presets.js";

test("Verify comes after the configured presets, on its own without any", () => {
  assert.deepEqual(withVerify(["Agreed", "Why?"]), ["Agreed", "Why?", VERIFY_PRESET]);
  assert.deepEqual(withVerify([]), [VERIFY_PRESET]);
  assert.deepEqual(withVerify(undefined), [VERIFY_PRESET]);
});

test("Verify's note: the quote, then the ask ending on the verdict line", () => {
  assert.equal(VERIFY_PRESET.label, "Verify");
  assert.equal(presetNote("> the count is wrong\n\n", VERIFY_PRESET.text),
    "> the count is wrong\n\nVerify this claim against the code. If this session's context doesn't settle it, say so. "
    + "End with a line `Verdict: confirmed|refuted|unclear — <one-line reason>`.");
});
