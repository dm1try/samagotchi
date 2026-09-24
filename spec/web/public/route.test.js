import test from "node:test";
import assert from "node:assert/strict";
import { sessionHash, sessionIdFromHash } from "../../../lib/samagotchi/web/public/route.js";

const ID = "d4c5c3af-a814-48dd-a59c-fffa4bc0b094";

test("a session's hash round-trips its id", () => {
  assert.equal(sessionHash(ID), `#/s/${ID}`);
  assert.equal(sessionIdFromHash(sessionHash(ID)), ID);
});

test("no session is no hash", () => {
  assert.equal(sessionHash(null), "");
  assert.equal(sessionHash(""), "");
});

test("other hashes name no session", () => {
  for (const h of ["", "#", "#/sessions", "#/s/", "#/s/a/b", "#s/abc", "#/s/%E0%A4%A"]) {
    assert.equal(sessionIdFromHash(h), null, h);
  }
  assert.equal(sessionIdFromHash(undefined), null);
});
