// A session's own view settings (session_prefs.js): the per-session key, the
// defaults (the page's, the module's), the start page's memory, the sweep.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

const {
  COMPOSER_FLOOR, COMPOSER_FOLD, PREF_KEYS, STAGE_FOLD, WS_RAIL_FOLD, forget, prefKey, read, sweepSessionPrefs, write,
} = await import("../../../lib/samagotchi/web/public/session_prefs.js");

function clean(t) {
  const wipe = () => {
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const key = localStorage.key(i);
      if (PREF_KEYS.some((k) => key === k || key?.startsWith(`${k}:`))) localStorage.removeItem(key);
    }
    for (const key of PREF_KEYS) forget(key, null);
    delete document.body.dataset.stageCollapsed;
  };
  wipe();
  t.after(wipe);
}

test("the keys: the view settings and the composer's draft, each as <key>:<session>", () => {
  assert.deepEqual(PREF_KEYS, ["chi_stage_collapsed", "chi_composer_floor", "chi_composer_collapsed", "chi_working_set_collapsed", "chi_ws_sections_folded", "chi_composer_draft"]);
  assert.equal(prefKey(STAGE_FOLD, "s1"), "chi_stage_collapsed:s1");
  assert.ok(prefKey(STAGE_FOLD, null) === null);
});

test("write: the session's key only; read: the session's own value, another session the default", (t) => {
  clean(t);
  write(COMPOSER_FLOOR, "a", 140);
  assert.equal(localStorage.getItem("chi_composer_floor:a"), "140");
  assert.ok(localStorage.getItem("chi_composer_floor") === null, "the global key is never written");
  assert.equal(read(COMPOSER_FLOOR, "a"), "140");
  assert.ok(read(COMPOSER_FLOOR, "b") === null);
  assert.equal(read(COMPOSER_FLOOR, "b", "x"), "x", "the module's own default");
});

test("the old global keys are not read", (t) => {
  clean(t);
  localStorage.setItem("chi_stage_collapsed", "1");
  localStorage.setItem("chi_working_set_collapsed", "1");
  assert.equal(read(STAGE_FOLD, "a", "0"), "0");
  assert.equal(read(WS_RAIL_FOLD, null, "0"), "0");
  sweepSessionPrefs([]);
  assert.equal(localStorage.getItem("chi_stage_collapsed"), "1", "left in storage");
});

test("the stage fold's default is the page's (<body data-stage-collapsed>); a session's own choice wins", (t) => {
  clean(t);
  assert.equal(read(STAGE_FOLD, "a", "0"), "0");
  document.body.dataset.stageCollapsed = "1";
  assert.equal(read(STAGE_FOLD, "a", "0"), "1");
  assert.equal(read(STAGE_FOLD, null, "0"), "1", "the start page too");
  write(STAGE_FOLD, "a", "0");
  assert.equal(read(STAGE_FOLD, "a", "0"), "0", "unfolded by hand");
  assert.equal(read(STAGE_FOLD, "b", "0"), "1");
  assert.ok(read(COMPOSER_FOLD, "b") === null, "no page default for the others");
});

test("no session (the start page): nothing written, the value in memory", (t) => {
  clean(t);
  const before = localStorage.length;
  write(COMPOSER_FLOOR, null, 200);
  assert.equal(localStorage.length, before);
  assert.equal(read(COMPOSER_FLOOR, null), "200");
  assert.ok(read(COMPOSER_FLOOR, "a") === null, "a session doesn't see it");
  forget(COMPOSER_FLOOR, null);
  assert.ok(read(COMPOSER_FLOOR, null) === null);
});

test("forget: the session follows the default again", (t) => {
  clean(t);
  write(COMPOSER_FLOOR, "a", 90);
  forget(COMPOSER_FLOOR, "a");
  assert.ok(localStorage.getItem("chi_composer_floor:a") === null);
  assert.ok(read(COMPOSER_FLOOR, "a") === null);
});

test("sweepSessionPrefs: an unscoped list drops the keys of sessions gone; a scoped list drops nothing", (t) => {
  clean(t);
  for (const key of PREF_KEYS) {
    write(key, "kept", "1");
    write(key, "gone", "1");
  }
  localStorage.setItem("chi_answer_fold:gone", "{}");
  t.after(() => localStorage.removeItem("chi_answer_fold:gone"));
  sweepSessionPrefs([{ id: "other" }], { scoped: true });
  for (const key of PREF_KEYS) assert.equal(localStorage.getItem(`${key}:gone`), "1", `${key}: a scoped list sweeps nothing`);
  sweepSessionPrefs([{ id: "kept" }, null, {}]);
  for (const key of PREF_KEYS) {
    assert.equal(localStorage.getItem(`${key}:kept`), "1");
    assert.ok(localStorage.getItem(`${key}:gone`) === null, `${key}: gone`);
  }
  assert.equal(localStorage.getItem("chi_answer_fold:gone"), "{}", "not its key");
});

test("sweepSessionPrefs: a gone session's draft goes with its view settings; the start page's draft stays", (t) => {
  clean(t);
  localStorage.setItem("chi_composer_draft:gone", "half a thought");
  localStorage.setItem("chi_composer_draft:kept", "mine");
  localStorage.setItem("chi_start_draft", "start text");
  t.after(() => localStorage.removeItem("chi_start_draft"));
  sweepSessionPrefs([{ id: "kept" }]);
  assert.ok(localStorage.getItem("chi_composer_draft:gone") === null);
  assert.equal(localStorage.getItem("chi_composer_draft:kept"), "mine");
  assert.equal(localStorage.getItem("chi_start_draft"), "start text");
});
