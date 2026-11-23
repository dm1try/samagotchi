// All sessions' Pages group (pages_group.js) and a #/p/ link opening its
// page in place (page_links.js).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createPagesGroup, filterPages, pageCardMeta } from "../../../lib/samagotchi/web/public/pages_group.js";
import { installPageLinks, pageLinkTarget } from "../../../lib/samagotchi/web/public/page_links.js";

const NOW = Date.parse("2026-11-23T12:00:00Z");
const ago = (minutes) => new Date(NOW - minutes * 60_000).toISOString();
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const PAGES = [
  { name: "release", title: "Release walk", state: "ok", ran_at: ago(60 * 24 * 2), failed_at: null, changed: false, error_line: null },
  { name: "usage", title: "Usage, last 7 days", state: "failed", ran_at: ago(300), failed_at: ago(60), changed: false, error_line: 9 },
  { name: "draft", title: null, state: "never_ran", ran_at: null, failed_at: null, changed: false, error_line: null },
];

test("a card's line: ran, failed (its failure's time), never ran", () => {
  assert.equal(pageCardMeta(PAGES[0], NOW), "ran 2 d ago");
  assert.equal(pageCardMeta(PAGES[1], NOW), "failed 1 h ago");
  assert.equal(pageCardMeta(PAGES[2], NOW), "never ran");
});

test("the search filters pages by name and title, any case", () => {
  assert.deepEqual(filterPages(PAGES, "").map((p) => p.name), ["release", "usage", "draft"]);
  assert.deepEqual(filterPages(PAGES, "USAGE").map((p) => p.name), ["usage"]);
  assert.deepEqual(filterPages(PAGES, "walk").map((p) => p.name), ["release"]);
  assert.deepEqual(filterPages(PAGES, "dra").map((p) => p.name), ["draft"]);
  assert.deepEqual(filterPages(PAGES, "zzz"), []);
});

function group(answer) {
  document.body.innerHTML = '<input id="filter"><div id="pagesGroup" hidden></div>';
  const root = document.querySelector("#pagesGroup");
  const filterEl = document.querySelector("#filter");
  const opened = [];
  const calls = [];
  const api = (path) => { calls.push(path); return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer); };
  const g = createPagesGroup({ root, filterEl, api, open: (name) => opened.push(name), now: () => NOW });
  return { g, root, filterEl, opened, calls };
}
const texts = (nodes) => [...nodes].map((n) => n.textContent.replace(/\s+/g, " ").trim());

test("the group: Pages, a card per page that opens it, then the Sessions heading; filtered by the search", async () => {
  const { g, root, filterEl, opened, calls } = group({ pages: PAGES });
  assert.equal(root.hidden, true, "nothing before the list is read");
  await g.load();
  assert.deepEqual(calls, ["/api/pages"]);
  assert.equal(root.hidden, false);
  assert.deepEqual(texts(root.querySelectorAll(".pg-group-label")), ["Pages", "Sessions"]);
  assert.deepEqual(texts(root.querySelectorAll(".pg-card")), ["Release walkran 2 d ago", "Usage, last 7 daysfailed 1 h ago", "draftnever ran"]);
  root.querySelectorAll(".pg-card")[1].click();
  assert.deepEqual(opened, ["usage"]);

  filterEl.value = "walk";
  filterEl.dispatchEvent(new window.Event("input"));
  assert.deepEqual(texts(root.querySelectorAll(".pg-card b")), ["Release walk"]);
  filterEl.value = "nothing like it";
  filterEl.dispatchEvent(new window.Event("input"));
  assert.equal(root.hidden, true);
  assert.ok(root.querySelector(".pg-group-label") === null, "no Sessions heading without the group");
});

test("no pages, or a list that can't be read: no group and no heading", async () => {
  const empty = group({ pages: [] });
  await empty.g.load();
  assert.equal(empty.root.hidden, true);
  assert.equal(empty.root.textContent.trim(), "");
  const failed = group(new Error("offline"));
  await failed.g.load();
  assert.equal(failed.root.hidden, true);
});

function click(target, init = {}) {
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init });
  target.dispatchEvent(event);
  return event;
}

test("a #/p/ link opens its page in place on a plain left click; other links and clicks keep the browser's way", async () => {
  document.body.innerHTML = `<div id="history"><p>
    <a id="page" href="#/p/usage" target="_blank" rel="noopener noreferrer">Usage</a>
    <a id="unknown" href="#/p/no-such" target="_blank"><span id="inner">x</span></a>
    <a id="session" href="#/s/abc" target="_blank">s</a>
    <a id="out" href="https://example.com" target="_blank">e</a>
    <a id="ref" href="#/p/usage" data-ref-kind="file">r</a></p></div>`;
  const opened = [];
  installPageLinks([document.querySelector("#history"), null], { open: (name) => opened.push(name) });
  const $ = (sel) => document.querySelector(sel);

  assert.equal(click($("#page")).defaultPrevented, true);
  assert.equal(click($("#inner")).defaultPrevented, true);
  assert.deepEqual(opened, ["usage", "no-such"]);
  for (const sel of ["#session", "#out", "#ref"]) assert.equal(click($(sel)).defaultPrevented, false, sel);
  assert.equal(click($("#page"), { metaKey: true }).defaultPrevented, false);
  assert.equal(click($("#page"), { ctrlKey: true }).defaultPrevented, false);
  assert.equal(click($("#page"), { shiftKey: true }).defaultPrevented, false);
  assert.equal(pageLinkTarget({ button: 1, target: $("#page") }), null, "a middle click");
  assert.deepEqual(opened, ["usage", "no-such"]);
});
