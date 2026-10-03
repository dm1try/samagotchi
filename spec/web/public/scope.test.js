import test from "node:test";
import assert from "node:assert/strict";
import { allScopeHref, cardFolder, projectScopeHref, scopeDir } from "../../../lib/samagotchi/web/public/scope.js";

test("scopeDir reads ?dir= and ignores a missing or blank one", () => {
  assert.equal(scopeDir("?dir=%2FUsers%2Fme%2Fproj"), "/Users/me/proj");
  assert.equal(scopeDir("?x=1&dir=/a%20b"), "/a b");
  assert.equal(scopeDir(""), null);
  assert.equal(scopeDir("?dir="), null);
  assert.equal(scopeDir("?dir=%20"), null);
});

test("allScopeHref drops ?dir and keeps the hash; the project it leaves goes in ?from=", () => {
  assert.equal(allScopeHref("#/s/abc"), "/#/s/abc");
  assert.equal(allScopeHref(""), "/");
  assert.equal(allScopeHref("#/s/abc", "/Users/me/my proj"), "/?from=/Users/me/my%20proj#/s/abc");
});

test("projectScopeHref: back to a folder's project view, keeping the hash", () => {
  assert.equal(projectScopeHref("/Users/me/proj", "#/sessions"), "/?dir=/Users/me/proj#/sessions");
  assert.equal(projectScopeHref("/a&b", ""), "/?dir=/a%26b");
});

test("the scope links keep the page's ?view= and drop its other params", () => {
  assert.equal(allScopeHref("#/s/abc", null, "?view=turn"), "/?view=turn#/s/abc");
  assert.equal(allScopeHref("", "/u/proj", "?dir=/u/proj&view=stage"), "/?from=/u/proj&view=stage");
  assert.equal(projectScopeHref("/u/proj", "#/sessions", "?from=/x&view=turn"), "/?dir=/u/proj&view=turn#/sessions");
  assert.equal(projectScopeHref("/u/proj", "", "?from=/x"), "/?dir=/u/proj");
});

test("cardFolder shows a folder only where the scope doesn't make it obvious", () => {
  assert.equal(cardFolder("/u/p/samagotchi", null), "samagotchi");
  assert.equal(cardFolder("/u/p/samagotchi/", "samagotchi"), "");
  assert.equal(cardFolder("/u/p/samagotchi-vision", "samagotchi"), "samagotchi-vision");
  assert.equal(cardFolder("", null), "");
});
