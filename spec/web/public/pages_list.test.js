// The Pages list (pages_list.js) and the pages pill (pages_wiring.js): the
// list's hash, its template (Loading…, No pages., a card per page that opens
// it), its view reading the list each time it opens, and when the pill shows.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { PAGES_HASH, createPagesList, pageCardMeta, pagesListOpen, pagesListTemplate } from "../../../lib/samagotchi/web/public/pages_list.js";
import { createPagesModel } from "../../../lib/samagotchi/web/public/pages_model.js";
import { wirePages } from "../../../lib/samagotchi/web/public/pages_wiring.js";

const NOW = Date.parse("2026-11-23T12:00:00Z");
const ago = (minutes) => new Date(NOW - minutes * 60_000).toISOString();
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const PAGES = [
  { name: "release", title: "Release walk", state: "ok", ran_at: ago(60 * 24 * 2), failed_at: null },
  { name: "usage", title: "Usage, last 7 days", state: "failed", ran_at: ago(300), failed_at: ago(60) },
  { name: "draft", title: null, state: "never_ran", ran_at: null, failed_at: null },
];
const texts = (nodes) => [...nodes].map((n) => n.textContent.replace(/\s+/g, " ").trim());

test("the list's hash: #/pages, for the owner with pages only; a page called pages is #/p/pages", () => {
  assert.equal(PAGES_HASH, "#/pages");
  assert.equal(pagesListOpen("#/pages", { canPages: true }), true);
  assert.equal(pagesListOpen("#/pages", { canPages: false }), false);
  assert.equal(pagesListOpen("#/pages", { canPages: true, participant: { sessionId: "x" } }), false);
  assert.equal(pagesListOpen("#/p/pages", { canPages: true }), false);
  assert.equal(pagesListOpen("#/pages/x", { canPages: true }), false);
});

test("a card's line: ran, failed (its failure's time), never ran", () => {
  assert.equal(pageCardMeta(PAGES[0], NOW), "ran 2 d ago");
  assert.equal(pageCardMeta(PAGES[1], NOW), "failed 1 h ago");
  assert.equal(pageCardMeta(PAGES[2], NOW), "never ran");
});

test("the template: Loading… before the first answer, No pages., else a card per page in the list's order", () => {
  const root = document.createElement("div");
  const opened = [];
  let backs = 0;
  const draw = (state) => render(pagesListTemplate(state, { open: (n) => opened.push(n), back: () => { backs += 1; }, now: NOW }), root);
  draw({ pages: [], loaded: false });
  assert.equal(root.querySelector(".pg-note").textContent, "Loading…");
  assert.equal(root.querySelector(".pg-title").textContent, "Pages");
  draw({ pages: [], loaded: true });
  assert.equal(root.querySelector(".pg-note").textContent, "No pages.");
  root.querySelector(".pg-back").click();
  assert.equal(backs, 1);
  draw({ pages: PAGES, loaded: true });
  assert.deepEqual(texts(root.querySelectorAll(".pg-card")), ["Release walkran 2 d ago", "Usage, last 7 daysfailed 1 h ago", "draftnever ran"]);
  root.querySelectorAll(".pg-card")[1].click();
  assert.deepEqual(opened, ["usage"]);
});

test("the view: draws only while open, reads the list each time it opens, and redraws on the list's answers", async () => {
  const root = document.createElement("div");
  const calls = [];
  const model = createPagesModel({ api: async (path) => { calls.push(path); return { pages: PAGES.slice(0, 1) }; } });
  const list = createPagesList({ root, model, open: () => {}, back: () => {}, now: () => NOW });
  await model.load();
  assert.equal(root.textContent.trim(), "", "closed: nothing drawn");
  list.open();
  assert.deepEqual(texts(root.querySelectorAll(".pg-card b")), ["Release walk"]);
  await tick();
  assert.equal(calls.length, 2);
  list.close();
  assert.equal(root.textContent.trim(), "");
  await model.reload();
  assert.equal(root.textContent.trim(), "", "closed: an answer draws nothing");
});

// The wiring on a stand-in page.
function wired({ can = true, answers = [], oldViews = false } = {}) {
  document.body.innerHTML = '<button id="pagesBtn" hidden>pages</button><section id="pageView"></section><section id="pagesList"></section>';
  const calls = [];
  const queue = [...answers];
  const api = async (path) => {
    calls.push(path);
    const next = queue.length > 1 ? queue.shift() : queue[0];
    if (next instanceof Error) throw next;
    return next;
  };
  const viewer = {
    can: (name) => can && name === "pages",
    control: (el, name) => { if (can && name === "pages") return el; el.hidden = true; el.dataset.withheld = ""; return null; },
  };
  const viewsCalls = [];
  const views = oldViews ? { openPage: (n) => viewsCalls.push(n) }
    : { openPagesList: () => viewsCalls.push("list"), openPage: (n) => viewsCalls.push(n) };
  const ui = wirePages({ viewer, $: (sel) => document.querySelector(sel), api, toast: () => {}, copyText: async () => true,
                         turnRoots: () => [], views: () => views, win: { matchMedia: () => ({ matches: false }) } });
  return { ui, calls, viewsCalls, pill: document.querySelector("#pagesBtn") };
}

test("the pill: hidden with no page, shown with one, opens the list; one read at boot", async () => {
  const none = wired({ answers: [{ pages: [] }] });
  await tick();
  assert.equal(none.pill.hidden, true);
  assert.deepEqual(none.calls, ["/api/pages"]);

  const one = wired({ answers: [{ pages: PAGES.slice(0, 1) }] });
  one.ui.allViewOpened(); // All sessions opened at boot: the boot's read
  one.ui.pagesList.open(); // and the list
  await tick();
  assert.deepEqual(one.calls, ["/api/pages"], "one request at boot");
  assert.equal(one.pill.hidden, false);
  one.pill.click();
  assert.deepEqual(one.viewsCalls, ["list"]);
});

test("the pill follows the list: a page made shows it, the last one removed hides it, a failed read keeps it", async () => {
  const h = wired({ answers: [{ pages: [] }, { pages: PAGES.slice(0, 1) }, new Error("restarting"), { pages: [] }] });
  await tick();
  assert.equal(h.pill.hidden, true);
  h.ui.changed();
  await tick();
  assert.equal(h.pill.hidden, false);
  h.ui.changed();
  await tick();
  assert.equal(h.pill.hidden, false, "a failed read keeps it");
  h.ui.changed();
  await tick();
  assert.equal(h.pill.hidden, true);
});

test("the hub's snapshots: the first loads (sharing the boot read while it is out), every later one (a reconnect) reads again", async () => {
  const h = wired({ answers: [{ pages: [] }] });
  h.ui.snapshot(); // the boot read is still out: shared
  await tick();
  assert.equal(h.calls.length, 1);
  h.ui.snapshot();
  await tick();
  assert.equal(h.calls.length, 2);

  // The first snapshot after the boot read ended: read again (a page made in between).
  const late = wired({ answers: [{ pages: [] }, { pages: PAGES.slice(0, 1) }] });
  await tick();
  assert.equal(late.pill.hidden, true);
  late.ui.snapshot();
  await tick();
  assert.equal(late.calls.length, 2);
  assert.equal(late.pill.hidden, false);
});

test("without the pages capability: no pill, nothing made, nothing read", async () => {
  const h = wired({ can: false, answers: [{ pages: PAGES }] });
  await tick();
  assert.ok(h.ui === null);
  assert.equal(h.pill.hidden, true);
  assert.ok("withheld" in h.pill.dataset);
  assert.deepEqual(h.calls, []);
});

test("an older cached views.js (no openPagesList): the pill stays hidden, as it would open nothing", async () => {
  const h = wired({ oldViews: true, answers: [{ pages: PAGES }] });
  await tick();
  assert.equal(h.pill.hidden, true);
});

test("a first read that failed: the list says so instead of Loading…; a later answer draws the cards", () => {
  const root = document.createElement("div");
  const draw = (state) => render(pagesListTemplate(state, { open: () => {}, back: () => {}, now: NOW }), root);
  draw({ pages: [], loaded: false, failed: true });
  assert.equal(root.querySelector(".pg-note").textContent, "Couldn't read the pages.");
  assert.ok(root.querySelector(".pg-back"), "Back is there");
  draw({ pages: PAGES, loaded: true, failed: true }); // a later read failed: the last list stays
  assert.equal(root.querySelectorAll(".pg-card").length, 3);
});
