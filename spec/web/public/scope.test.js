import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { allScopeHref, cardFolder, projectScopeHref, scopeDir, scopeTemplate } from "../../../lib/samagotchi/web/public/scope.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

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

test("scopeTemplate: a project's name and its all link; a folder not found; all projects with the way back and where a new chat starts, escaped", () => {
  const where = () => ({ hash: "#/s/abc", search: "?view=turn" });
  assert.equal(markupOf(scopeTemplate({ dir: "/p/chi", projectName: "chi", projectDir: "/p/chi" }, { where })),
    '<span class="scope-name" title="Sessions of /p/chi">chi</span>' +
    '<a class="scope-all" href="/?from=/p/chi&amp;view=turn#/s/abc" title="Sessions of every project">all</a>');
  assert.match(markupOf(scopeTemplate({ dir: "/nope" }, { error: "no <such> folder", where })),
    /^<span class="scope-name error" title="no <such> folder">folder not found<\/span><a class="scope-all"/);
  assert.equal(markupOf(scopeTemplate({ serverDir: "/srv/<x>", backDir: "/p/chi", backName: "chi" }, { where })),
    '<span class="scope-name" title="Sessions of every project">all projects</span>' +
    '<a class="scope-all scope-back" href="/?dir=/p/chi&amp;view=turn#/s/abc" title="Sessions of chi only">← chi</a>' +
    '<span class="scope-where" title="New chats start in /srv/<x>">new chat in<span class="path"><bdi>/srv/&lt;x&gt;</bdi></span></span>');
});

test("scopeTemplate: a link clicked takes the hash the page has then; drawn again, the chip keeps its elements and one listener", () => {
  let at = { hash: "", search: "" };
  const where = () => at;
  const el = document.createElement("div");
  const scope = { dir: "/p/chi", projectName: "chi", projectDir: "/p/chi" };
  render(scopeTemplate(scope, { where }), el);
  const link = el.querySelector(".scope-all");
  render(scopeTemplate(scope, { where }), el);
  assert.ok(el.querySelector(".scope-all") === link);
  at = { hash: "#/sessions", search: "" };
  let hrefs = 0;
  link.addEventListener("click", () => { hrefs += 1; });
  link.dispatchEvent(new window.Event("click", { cancelable: true }));
  assert.equal(link.getAttribute("href"), "/?from=/p/chi#/sessions");
  assert.equal(hrefs, 1);
});
