import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { applyComposerText, applyRowTemplate, applyURL, fetchApply } from "../../../lib/samagotchi/web/public/review_apply.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};

test("apply: the row names the participant and carries the turn; the composer keeps what is typed", () => {
  const out = markupOf(applyRowTemplate("rev-1", { author: "p:p_1", name: "Alex", color: "var(--author-2)" }));
  assert.match(out, /class="review-apply"[^>]*data-apply-turn="rev-1"/);
  assert.match(out, /<button[^>]*class="review-apply-btn"[^>]*>Apply<\/button>/);
  assert.match(out, /Alex's proposal, quoted in your composer; you send it/);
  assert.equal(applyComposerText("", "Apply this"), "Apply this");
  assert.equal(applyComposerText("my note  \n", "Apply this"), "my note\n\nApply this");
  assert.equal(applyURL("a b", "t/1"), "/api/sessions/a%20b/apply?turn=t%2F1");
});

test("apply: the server's text, or its words as the error", async () => {
  const ok = async () => ({ ok: true, status: 200, json: async () => ({ text: "Apply …\n\n> x" }) });
  assert.equal(await fetchApply("s", "t", ok), "Apply …\n\n> x");
  const refused = async () => ({ ok: false, status: 409, json: async () => ({ error: "no_reply", detail: "review turn t has no reply to apply yet" }) });
  await assert.rejects(fetchApply("s", "t", refused), /no reply to apply yet/);
});
