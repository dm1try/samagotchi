import test from "node:test";
import assert from "node:assert/strict";
import { updateNotice } from "../../../lib/samagotchi/web/public/update_notice.js";

test("updateNotice: a snapshot from another chi version than the page's asks for a reload", () => {
  assert.equal(updateNotice("0.17.0", "0.18.0"), "chi was updated to 0.18.0");
});

test("updateNotice: the same version, or one side unknown (an older chi web, a page without it), says nothing", () => {
  assert.equal(updateNotice("0.17.0", "0.17.0"), null);
  assert.equal(updateNotice("0.17.0", undefined), null);
  assert.equal(updateNotice("0.17.0", ""), null);
  assert.equal(updateNotice("", "0.18.0"), null);
  assert.equal(updateNotice(undefined, "0.18.0"), null);
  assert.equal(updateNotice("0.17.0", 18), null);
});

test("updateNotice: once per version (each reconnect's snapshot carries it again)", () => {
  assert.equal(updateNotice("0.17.0", "0.18.0", "0.18.0"), null);
  assert.equal(updateNotice("0.17.0", "0.19.0", "0.18.0"), "chi was updated to 0.19.0");
});
