import test from "node:test";
import assert from "node:assert/strict";
import { compareVersions, newerVersion, restartConfirmText, versionNotice, workerBadge } from "../../../lib/samagotchi/web/public/update_notice.js";

test("versionNotice: a snapshot from another chi version than the page's asks for a reload", () => {
  assert.deepEqual(versionNotice({ loaded: "0.17.0", served: "0.18.0" }),
    { key: "reload:0.18.0", text: "chi was updated to 0.18.0", reload: true });
});

test("versionNotice: the same version, or one side unknown (an older chi web, a page without it), says nothing", () => {
  assert.equal(versionNotice({ loaded: "0.17.0", served: "0.17.0" }), null);
  assert.equal(versionNotice({ loaded: "0.17.0", served: undefined }), null);
  assert.equal(versionNotice({ loaded: "0.17.0", served: "" }), null);
  assert.equal(versionNotice({ loaded: "", served: "0.18.0" }), null);
  assert.equal(versionNotice({ loaded: undefined, served: "0.18.0" }), null);
  assert.equal(versionNotice({ loaded: "0.17.0", served: 18 }), null);
  assert.equal(versionNotice(), null);
});

test("versionNotice: a newer chi installed than chi web runs says to restart chi web, with no action", () => {
  assert.deepEqual(versionNotice({ loaded: "0.18.1", served: "0.18.1", installed: "0.19.0" }), {
    key: "installed:0.19.0",
    text: "chi 0.19.0 is installed; this chi web runs 0.18.1. Restart it: Ctrl-C in its terminal, then chi web",
    reload: false,
  });
  assert.equal(versionNotice({ loaded: "0.18.1", served: "0.18.1", installed: "0.18.1" }), null);
  assert.equal(versionNotice({ loaded: "0.18.1", served: "0.18.1", installed: "0.17.0" }), null);
  assert.equal(versionNotice({ loaded: "0.18.1", served: "0.18.1", installed: null }), null);
});

test("versionNotice: the reload comes first (the reloaded page then hears about the installed one)", () => {
  assert.equal(versionNotice({ loaded: "0.17.0", served: "0.18.0", installed: "0.19.0" }).key, "reload:0.18.0");
});

test("versionNotice: once per notice (each reconnect's snapshot carries it again)", () => {
  assert.equal(versionNotice({ loaded: "0.17.0", served: "0.18.0", shown: new Set(["reload:0.18.0"]) }), null);
  assert.equal(versionNotice({ loaded: "0.17.0", served: "0.19.0", shown: new Set(["reload:0.18.0"]) }).key,
    "reload:0.19.0");
  const shown = new Set(["installed:0.19.0"]);
  assert.equal(versionNotice({ loaded: "0.18.1", served: "0.18.1", installed: "0.19.0", shown }), null);
  assert.equal(versionNotice({ loaded: "0.18.1", served: "0.18.1", installed: "0.19.1", shown }).key, "installed:0.19.1");
});

test("compareVersions: Gem::Version's order, prereleases below their release", () => {
  assert.ok(compareVersions("0.18.10", "0.18.9") > 0);
  assert.equal(compareVersions("1.0", "1"), 0);
  assert.ok(compareVersions("0.19.0.pre1", "0.19.0") < 0);
  assert.ok(compareVersions("0.19.0.pre1", "0.18.1") > 0);
  assert.ok(compareVersions("0.19.0.pre2", "0.19.0.pre10") < 0);
  assert.ok(compareVersions("0.19.0.beta", "0.19.0.alpha") > 0);
  assert.equal(newerVersion("0.19.0", null), false);
  assert.equal(newerVersion("0.19.0", "0.18.1"), true);
});

test("workerBadge: a worker on an older chi than the newest installed offers Restart when it can", () => {
  const badge = workerBadge({ workerVersion: "0.18.1", features: ["restart"], installed: "0.19.0", served: "0.18.1",
                              sessionId: "abcdef123456" });
  assert.deepEqual(badge, {
    text: "chi 0.18.1",
    title: "This session's worker runs chi 0.18.1; chi 0.19.0 is installed. Restart hands the session to a new worker on chi 0.19.0.",
    newest: "0.19.0",
    restart: true,
  });
});

test("workerBadge: a worker from before restarts gets the stop command, no button", () => {
  const badge = workerBadge({ workerVersion: "0.18.1", features: [], installed: "0.19.0", sessionId: "abcdef123456" });
  assert.equal(badge.restart, false);
  assert.equal(badge.text, "chi 0.18.1 · chi sessions stop abcdef12");
  assert.match(badge.title, /can't restart itself.*then any message starts it on chi 0\.19\.0/);
});

test("workerBadge: compares with chi web's own version while the installed one is unknown", () => {
  assert.equal(workerBadge({ workerVersion: "0.17.0", features: ["restart"], installed: null, served: "0.18.1" }).newest,
    "0.18.1");
});

test("workerBadge: nothing for a current worker, an unknown version or nothing to compare with", () => {
  assert.equal(workerBadge({ workerVersion: "0.19.0", features: ["restart"], installed: "0.19.0", served: "0.18.1" }), null);
  assert.equal(workerBadge({ workerVersion: "0.20.0", features: ["restart"], installed: "0.19.0" }), null);
  assert.equal(workerBadge({ workerVersion: null, features: [], installed: "0.19.0" }), null);
  assert.equal(workerBadge({ workerVersion: "0.18.1", features: [], installed: null, served: null }), null);
  assert.equal(workerBadge(), null);
});

test("restartConfirmText: names both versions and what goes", () => {
  const text = restartConfirmText("0.18.1", "0.19.0");
  assert.match(text, /^Restart this session's worker on chi 0\.19\.0 \(it runs 0\.18\.1\)\?/);
  assert.match(text, /kept \/btw answers and plugins' in-memory state/);
});
