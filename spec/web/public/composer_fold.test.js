import test from "node:test";
import assert from "node:assert/strict";
import { COMPOSER_FOLD_KEY, composerFolded, foldHandle, opensOnKey } from "../../../lib/samagotchi/web/public/composer_fold.js";

test("COMPOSER_FOLD_KEY: the per-browser key", () => {
  assert.equal(COMPOSER_FOLD_KEY, "chi_composer_collapsed");
});

test("composerFolded: the saved choice (no storage: expanded)", () => {
  assert.equal(composerFolded({ saved: true, archivedVisit: false, visitOpen: false }), true);
  assert.equal(composerFolded({ saved: false, archivedVisit: false, visitOpen: false }), false);
  assert.equal(composerFolded({}), false);
});

test("composerFolded: an archived session's visit opens folded whatever was saved", () => {
  assert.equal(composerFolded({ saved: false, archivedVisit: true, visitOpen: false }), true);
  assert.equal(composerFolded({ saved: true, archivedVisit: true, visitOpen: false }), true);
});

test("composerFolded: a visit the page opened stays open, saved or archived", () => {
  assert.equal(composerFolded({ saved: true, archivedVisit: false, visitOpen: true }), false);
  assert.equal(composerFolded({ saved: false, archivedVisit: true, visitOpen: true }), false);
  assert.equal(composerFolded({ saved: true, archivedVisit: true, visitOpen: true }), false);
});

test("foldHandle: expanded is unmarked, whatever the draft or a wait, and says how to hide", () => {
  const h = foldHandle({ folded: false, draft: true, waiting: true });
  assert.equal(h.folded, false);
  assert.equal(h.draft, false);
  assert.equal(h.waiting, false);
  assert.match(h.title, /down to hide it/);
  assert.deepEqual(Object.keys(h).sort(), ["draft", "folded", "title", "waiting"]);
});

test("foldHandle: folded says to pull up or click; a draft marks it and is in the title", () => {
  assert.deepEqual(foldHandle({ folded: true, draft: false, waiting: false }),
                   { title: "Pull up or click to write", folded: true, draft: false, waiting: false });
  const d = foldHandle({ folded: true, draft: true, waiting: false });
  assert.equal(d.draft, true);
  assert.equal(d.title, "Pull up or click to write · a draft is in it");
});

test("foldHandle: a session waiting on the user marks the folded handle and says so", () => {
  const w = foldHandle({ folded: true, draft: false, waiting: true });
  assert.equal(w.waiting, true);
  assert.equal(w.draft, false);
  assert.equal(w.title, "Pull up or click to write · the session waits on you");
  assert.equal(foldHandle({ folded: true, draft: true, waiting: true }).title, "Pull up or click to write · a draft is in it · the session waits on you");
});

const key = (k, extra = {}) => ({ key: k, defaultPrevented: false, isComposing: false, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...extra });
const page = { active: { tagName: "BODY" }, allView: false, lightbox: false };

test("opensOnKey: a printable key on the page opens it (Shift for capitals too)", () => {
  assert.equal(opensOnKey(key("h"), page), true);
  assert.equal(opensOnKey(key("H", { shiftKey: true }), page), true);
  assert.equal(opensOnKey(key("?"), page), true);
  assert.equal(opensOnKey(key("é"), page), true);
  assert.equal(opensOnKey(key("😀"), page), true);
  // A non-editable element in the history (a ref, a button) has the focus.
  assert.equal(opensOnKey(key("h"), { ...page, active: { tagName: "BUTTON" } }), true);
  assert.equal(opensOnKey(key("h"), { ...page, active: null }), true);
});

test("opensOnKey: not Space, Enter, arrows, Esc, Tab, an IME's Process", () => {
  for (const k of [" ", "Enter", "ArrowDown", "Escape", "Tab", "Process", "Shift", "F5", "Backspace", ""]) {
    assert.equal(opensOnKey(key(k), page), false, k);
  }
});

test("opensOnKey: not with Ctrl/Meta/Alt, a taken key or mid-composition", () => {
  assert.equal(opensOnKey(key("c", { ctrlKey: true }), page), false);
  assert.equal(opensOnKey(key("c", { metaKey: true }), page), false);
  assert.equal(opensOnKey(key("c", { altKey: true }), page), false);
  assert.equal(opensOnKey(key("c", { defaultPrevented: true }), page), false);
  assert.equal(opensOnKey(key("c", { isComposing: true }), page), false);
  assert.equal(opensOnKey(null, page), false);
});

test("opensOnKey: not while a field has the focus (input, textarea, select, contenteditable)", () => {
  for (const tagName of ["INPUT", "TEXTAREA", "SELECT", "input"]) {
    assert.equal(opensOnKey(key("h"), { ...page, active: { tagName } }), false, tagName);
  }
  assert.equal(opensOnKey(key("h"), { ...page, active: { tagName: "DIV", isContentEditable: true } }), false);
});

test("opensOnKey: not while the all-sessions view or the lightbox is open", () => {
  assert.equal(opensOnKey(key("h"), { ...page, allView: true }), false);
  assert.equal(opensOnKey(key("h"), { ...page, lightbox: true }), false);
});
