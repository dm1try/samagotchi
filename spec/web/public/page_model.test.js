// A page's hash (page_route.js) and the words its header and state lines
// say (page_model.js), from the page's JSON.
import test from "node:test";
import assert from "node:assert/strict";
import { openPageName, pageHash, pageNameFromHash } from "../../../lib/samagotchi/web/public/page_route.js";
import {
  changedText, durationText, errorCopy, failureParts, keptAfterFailure, metaText, resultDate,
} from "../../../lib/samagotchi/web/public/page_model.js";

const NOW = Date.parse("2026-11-23T12:00:00Z");
const ago = (minutes) => new Date(NOW - minutes * 60_000).toISOString();

test("the page hash: #/p/NAME, written and read as it is", () => {
  assert.equal(pageHash("usage"), "#/p/usage");
  assert.equal(pageNameFromHash("#/p/usage"), "usage");
  assert.equal(pageNameFromHash("#/p/Bad%20Name"), "Bad%20Name");
  for (const hash of ["", "#/", "#/sessions", "#/s/abc", "#/p/", "#/p/a/b", "#/p/a?x=1", null, undefined]) {
    assert.equal(pageNameFromHash(hash), null, String(hash));
  }
});

test("a page opens for the owner with the capability, never for a participant or without it", () => {
  assert.equal(openPageName("#/p/usage", { canPages: true }), "usage");
  assert.equal(openPageName("#/p/usage", { canPages: false }), null);
  assert.equal(openPageName("#/p/usage", { canPages: true, participant: { sessionId: "s" } }), null);
  assert.equal(openPageName("#/sessions", { canPages: true }), null);
});

test("the header's meta: when it ran and how long it took, never ran, none for a failure", () => {
  assert.equal(metaText({ state: "ok", ran_at: ago(2), duration_ms: 812 }, NOW), "ran 2 min ago · 0.8 s");
  assert.equal(metaText({ state: "ok", ran_at: ago(2), duration_ms: 12_400 }, NOW), "ran 2 min ago · 12 s");
  assert.equal(metaText({ state: "ok", ran_at: ago(180), duration_ms: null }, NOW), "ran 3 h ago");
  assert.equal(metaText({ state: "never_ran", ran_at: null }, NOW), "never ran");
  assert.equal(metaText({ state: "failed", ran_at: ago(2) }, NOW), null);
  assert.equal(durationText(undefined), "");
  assert.equal(durationText(12), "< 0.1 s");
  assert.equal(durationText(60), "0.1 s");
});

test("the failed-run line names the line and when the kept result is from", () => {
  const page = { state: "failed", ran_at: "2026-11-21T14:02:00", error: { message: "undefined method 'fetch' for nil", line: 9 } };
  assert.deepEqual(failureParts(page), {
    lead: "The script failed at line 9: ", message: "undefined method 'fetch' for nil",
    tail: ` Showing the result from ${resultDate(page.ran_at)}.`,
  });
  assert.equal(resultDate("2026-11-21T14:02:00"), "21 Nov, 14:02");
  assert.ok(keptAfterFailure(page));
  // No earlier result: the line without its second sentence; a cut has no line.
  const first = { state: "failed", ran_at: null, error: { message: "the script was stopped after 30 s", line: null } };
  assert.deepEqual(failureParts(first), { lead: "The script failed: ", message: "the script was stopped after 30 s", tail: "" });
  assert.equal(keptAfterFailure(first), false);
  assert.equal(failureParts({ state: "ok", ran_at: ago(1), error: null }), null);
});

test("the changed line: only when the result came from an older script and no failure says it already", () => {
  const base = { state: "ok", ran_at: ago(180), changed: true, script_changed_at: ago(12) };
  assert.equal(changedText(base, NOW),
    "The script changed 12 min ago. This is the result of the earlier version; Refresh runs the new one.");
  assert.equal(changedText({ ...base, changed: false }, NOW), null);
  assert.equal(changedText({ ...base, state: "failed", changed_after_failure: false }, NOW), null);
  assert.match(changedText({ ...base, state: "failed", changed_after_failure: true }, NOW), /^The script changed/);
  assert.equal(changedText({ ...base, ran_at: null }, NOW), null);
});

test("Copy the error: the line and message, then the script's last words", () => {
  const page = { error: { message: "boom", line: 4 } };
  assert.equal(errorCopy(page), "line 4: boom");
  assert.equal(errorCopy(page, "warn\nlast words\n"), "line 4: boom\n\nwarn\nlast words");
  assert.equal(errorCopy({ error: { message: "the run was stopped", line: null } }), "the run was stopped");
  assert.equal(errorCopy({ error: null }), "");
});
