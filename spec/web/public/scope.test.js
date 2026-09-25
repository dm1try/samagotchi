import test from "node:test";
import assert from "node:assert/strict";
import { allScopeHref, cardFolder, scopeDir } from "../../../lib/samagotchi/web/public/scope.js";

test("scopeDir reads ?dir= and ignores a missing or blank one", () => {
  assert.equal(scopeDir("?dir=%2FUsers%2Fme%2Fproj"), "/Users/me/proj");
  assert.equal(scopeDir("?x=1&dir=/a%20b"), "/a b");
  assert.equal(scopeDir(""), null);
  assert.equal(scopeDir("?dir="), null);
  assert.equal(scopeDir("?dir=%20"), null);
});

test("allScopeHref drops ?dir and keeps the hash", () => {
  assert.equal(allScopeHref("#/s/abc"), "/#/s/abc");
  assert.equal(allScopeHref(""), "/");
});

test("cardFolder shows a folder only where the scope doesn't make it obvious", () => {
  assert.equal(cardFolder("/u/p/samagotchi", null), "samagotchi");
  assert.equal(cardFolder("/u/p/samagotchi/", "samagotchi"), "");
  assert.equal(cardFolder("/u/p/samagotchi-vision", "samagotchi"), "samagotchi-vision");
  assert.equal(cardFolder("", null), "");
});
