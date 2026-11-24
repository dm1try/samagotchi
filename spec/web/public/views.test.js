// The page's views by hash (views.js): All sessions at #/sessions opened,
// closed and left, the session's own hash, and what a hash change selects.
// Moved out of app.js as it was: these pin its behaviour with stand-ins.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createViews } from "../../../lib/samagotchi/web/public/views.js";

const ID = "d4c5c3af-a814-48dd-a59c-fffa4bc0b094";
const OTHER = "0a1b2c3d-1111-2222-3333-444455556666";

function harness({ hash = "", participant = null, selected = null, events = true, pages = undefined, list = false } = {}) {
  const calls = [];
  const listeners = {};
  const location = { pathname: "/", search: "?dir=x", hash };
  const win = {
    location,
    history: {
      back: () => calls.push(["back"]),
      replaceState: (_s, _t, url) => {
        calls.push(["replace", url]);
        location.hash = url.slice(url.indexOf("#") >= 0 ? url.indexOf("#") : url.length);
      },
    },
    addEventListener: (name, fn) => { listeners[name] = fn; },
  };
  document.body.className = "";
  document.body.innerHTML = '<button id="stripStatus"></button><button id="pagesBtn"></button><input id="filter"><div id="topStrip"></div>';
  const store = {
    selected,
    sessions: [{ id: "b", updated_at: "1" }, { id: "a", updated_at: "2" }],
    update: (fields) => { calls.push(["update", fields]); Object.assign(store, fields); },
  };
  const lists = {
    selecting: { on: false, running: false },
    leaveSelect: () => calls.push(["leaveSelect"]),
    chainPop: { close: () => calls.push(["chainPop.close"]) },
    familyPop: { close: () => calls.push(["familyPop.close"]) },
  };
  const pageCalls = [];
  const pageView = pages === null ? null : {
    open: (name) => pageCalls.push(["open", name]), close: () => pageCalls.push(["close"]),
  };
  const listCalls = [];
  const pagesList = list ? { open: () => listCalls.push("open"), close: () => listCalls.push("close") } : null;
  const claims = { pending: (c) => calls.push(["claim.pending", c]), showPending: () => calls.push(["claim.show"]) };
  const views = createViews({
    win, doc: document, participant, store, lists,
    topStripEl: document.querySelector("#topStrip"),
    pictures: { close: () => calls.push(["pictures.close"]) },
    eventsLive: () => events,
    refresh: () => calls.push(["refresh"]),
    updateSessionTitle: () => calls.push(["title"]),
    select: (id) => calls.push(["select", id]),
    clearSelection: () => calls.push(["clear"]),
    ownerClaim: () => claims,
    pages: pageView,
    pagesList,
  });
  return { views, calls, location, listeners, store, lists, pageCalls, listCalls };
}

test("All sessions is open at #/sessions, never on a participant's page", () => {
  assert.equal(harness({ hash: "#/sessions" }).views.allViewOpen(), true);
  assert.equal(harness({ hash: `#/s/${ID}` }).views.allViewOpen(), false);
  const participant = { sessionId: ID };
  assert.equal(harness({ hash: "#/sessions", participant }).views.allViewOpen(), false);
});

test("opening pushes the hash; closing then goes back", () => {
  const { views, calls, location } = harness({ hash: `#/s/${ID}`, selected: ID });
  views.openAllView();
  assert.equal(location.hash, "#/sessions");
  views.closeAllView();
  assert.deepEqual(calls.at(-1), ["back"]);
});

test("closing a view the page didn't push replaces it with the session's hash", () => {
  const { views, calls, location } = harness({ hash: "#/sessions", selected: ID });
  views.closeAllView();
  assert.deepEqual(calls.find((c) => c[0] === "replace"), ["replace", `/?dir=x#/s/${ID}`]);
  assert.equal(location.hash, `#/s/${ID}`);
  assert.equal(document.body.classList.contains("all-view"), false);
});

test("the session's hash is replaced, and not written while All sessions is open", () => {
  const open = harness({ hash: "#/sessions" });
  open.views.setSessionHash(ID);
  assert.equal(open.calls.some((c) => c[0] === "replace"), false);

  const { views, calls } = harness({ hash: `#/s/${OTHER}` });
  views.setSessionHash(ID);
  assert.deepEqual(calls, [["replace", `/?dir=x#/s/${ID}`]]);
  views.setSessionHash(ID);
  assert.equal(calls.length, 1); // the same hash: no write
});

test("applyView at #/sessions shows the view in the server's order and refreshes without the stream", () => {
  const { views, calls, store } = harness({ hash: "#/sessions", events: false });
  views.applyView();
  assert.equal(document.body.classList.contains("all-view"), true);
  assert.equal(document.querySelector("#stripStatus").getAttribute("aria-pressed"), "true");
  assert.deepEqual(store.sessions.map((s) => s.id), ["a", "b"]);
  assert.ok(calls.some((c) => c[0] === "refresh"));
  assert.ok(calls.some((c) => c[0] === "pictures.close"));
});

test("leaving the view ends select mode unless a batch runs", () => {
  const { views, calls, lists } = harness({ hash: "" });
  lists.selecting.on = true;
  views.applyView();
  assert.ok(calls.some((c) => c[0] === "leaveSelect"));
  assert.equal(document.querySelector("#stripStatus").getAttribute("aria-pressed"), "false");
});

test("a hash change applies the view and selects the session it names", () => {
  const { calls, location, listeners } = harness({ hash: "", selected: OTHER });
  location.hash = `#/s/${ID}`;
  listeners.hashchange();
  assert.ok(calls.some((c) => c[0] === "title"));
  assert.deepEqual(calls.filter((c) => c[0] === "select"), [["select", ID]]);
});

test("the start page's hash with a session open clears it; a participant's page keeps its one session", () => {
  const start = harness({ hash: "#/", selected: ID });
  start.views.selectFromHash();
  assert.ok(start.calls.some((c) => c[0] === "clear"));

  const own = harness({ hash: `#/s/${OTHER}`, participant: { sessionId: ID } });
  own.views.selectFromHash();
  assert.deepEqual(own.calls.filter((c) => c[0] === "select"), [["select", ID]]);
});

test("a page hash opens the page view in place of the session area, and selects nothing", () => {
  const { views, calls, pageCalls, location, listeners } = harness({ hash: "", selected: ID });
  location.hash = "#/p/usage";
  listeners.hashchange();
  assert.equal(document.body.classList.contains("page-view"), true);
  assert.equal(document.body.classList.contains("all-view"), false);
  assert.deepEqual(pageCalls, [["open", "usage"]]);
  assert.equal(views.pageOpen(), "usage");
  assert.equal(calls.some((c) => c[0] === "select" || c[0] === "clear"), false);
  location.hash = `#/s/${ID}`;
  listeners.hashchange();
  assert.equal(document.body.classList.contains("page-view"), false);
  assert.deepEqual(pageCalls.at(-1), ["close"]);
});

test("no page without the capability, and none on a participant's page", () => {
  const none = harness({ hash: "#/p/usage", pages: null });
  none.views.applyView();
  assert.equal(none.views.pageOpen(), null);
  assert.equal(document.body.classList.contains("page-view"), false);

  const own = harness({ hash: "#/p/usage", participant: { sessionId: ID } });
  own.views.applyView();
  assert.equal(own.views.pageOpen(), null);
  assert.deepEqual(own.pageCalls, [["close"]]);
});

test("while a page is open the session's hash isn't written; a session picked leaves the page for it", () => {
  const { views, calls, location } = harness({ hash: "#/p/usage", selected: ID });
  views.setSessionHash(null);
  assert.equal(calls.some((c) => c[0] === "replace"), false);
  views.setSessionHash(OTHER);
  assert.deepEqual(calls.find((c) => c[0] === "replace"), ["replace", `/?dir=x#/s/${OTHER}`]);
  assert.equal(location.hash, `#/s/${OTHER}`);
});

test("Back (no Pages list given: an older cached app.js): history.back() when this page opened it, else All sessions in its entry; the label says where", () => {
  const pushed = harness({ hash: `#/s/${ID}`, selected: ID });
  pushed.views.openPage("usage");
  assert.equal(pushed.location.hash, "#/p/usage");
  assert.equal(pushed.views.pageBackLabel(), "Back");
  pushed.views.closePage();
  assert.deepEqual(pushed.calls.at(-1), ["back"]);

  const fromAll = harness({ hash: "#/sessions" });
  fromAll.views.openPage("usage");
  assert.equal(fromAll.views.pageBackLabel(), "Sessions");

  const loaded = harness({ hash: "#/p/usage" });
  assert.equal(loaded.views.pageBackLabel(), "Sessions");
  loaded.views.closePage();
  assert.deepEqual(loaded.calls.find((c) => c[0] === "replace"), ["replace", "/?dir=x#/sessions"]);
  assert.equal(loaded.location.hash, "#/sessions");

  const gone = harness({ hash: "#/p/usage" });
  gone.views.leavePage();
  assert.equal(gone.location.hash, "#/sessions");
});

test("Back from a page returns to All sessions; Esc then goes back to the session", () => {
  const { views, calls, location, listeners } = harness({ hash: `#/s/${ID}`, selected: ID });
  views.openAllView();
  location.hash = "#/sessions";
  listeners.hashchange();
  views.openPage("usage");
  location.hash = "#/p/usage";
  listeners.hashchange();
  views.closePage();
  location.hash = "#/sessions";
  listeners.hashchange();
  views.closeAllView();
  assert.deepEqual(calls.filter(([kind]) => kind === "back"), [["back"], ["back"]]);
});

// The Pages list, #/pages (the pages pill).
const pressed = () => document.querySelector("#pagesBtn").getAttribute("aria-pressed");
const go = (h, hash) => { h.location.hash = hash; h.listeners.hashchange(); };

test("#/pages opens the list in place of the session area, selects nothing, and presses the pages pill", () => {
  const h = harness({ hash: "", selected: ID, list: true });
  go(h, "#/pages");
  assert.equal(h.views.listOpen(), true);
  assert.equal(document.body.classList.contains("pages-list"), true);
  assert.equal(document.body.classList.contains("page-view"), false);
  assert.deepEqual(h.listCalls, ["open"]);
  assert.equal(pressed(), "true");
  assert.equal(h.calls.some((c) => c[0] === "select" || c[0] === "clear"), false);
  go(h, `#/s/${ID}`);
  assert.equal(document.body.classList.contains("pages-list"), false);
  assert.equal(h.listCalls.at(-1), "close");
  assert.equal(pressed(), "false");
});

test("no list without the capability, and none on a participant's page", () => {
  const none = harness({ hash: "#/pages", list: false });
  none.views.applyView();
  assert.equal(none.views.listOpen(), false);
  assert.equal(document.body.classList.contains("pages-list"), false);
  const own = harness({ hash: "#/pages", participant: { sessionId: ID }, list: true });
  own.views.applyView();
  assert.equal(own.views.listOpen(), false);
});

test("the pill: from a session pushes #/pages; on the list already, nothing; a page is pressed too", () => {
  const h = harness({ hash: `#/s/${ID}`, selected: ID, list: true });
  h.views.openPagesList();
  assert.equal(h.location.hash, "#/pages");
  h.listeners.hashchange();
  h.views.openPagesList();
  assert.equal(h.calls.some((c) => c[0] === "replace" || c[0] === "back"), false);
  h.views.openPage("usage");
  go(h, "#/p/usage");
  assert.equal(pressed(), "true");
  assert.equal(h.views.pageBackLabel(), "Pages");
});

test("pill -> list -> card -> Back -> list -> Back: two history.back()s, back on the session", () => {
  const h = harness({ hash: `#/s/${ID}`, selected: ID, list: true });
  h.views.openPagesList();
  h.listeners.hashchange();
  h.views.openPage("usage");
  h.listeners.hashchange();
  h.views.closePage();
  go(h, "#/pages");
  assert.equal(h.views.listOpen(), true);
  h.views.closePagesList();
  assert.deepEqual(h.calls.filter(([kind]) => kind === "back"), [["back"], ["back"]]);
});

test("a list or page with nowhere to go back to: the list leaves for the session's hash, a page for the list", () => {
  const list = harness({ hash: "#/pages", selected: ID, list: true });
  list.views.applyView();
  list.views.closePagesList();
  assert.deepEqual(list.calls.find((c) => c[0] === "replace"), ["replace", `/?dir=x#/s/${ID}`]);

  const loaded = harness({ hash: "#/p/usage", list: true });
  assert.equal(loaded.views.pageBackLabel(), "Pages");
  loaded.views.closePage();
  assert.equal(loaded.location.hash, "#/pages");

  const gone = harness({ hash: "#/p/usage", list: true });
  gone.views.leavePage();
  assert.equal(gone.location.hash, "#/pages");

  const fromAnswer = harness({ hash: `#/s/${ID}`, selected: ID, list: true });
  fromAnswer.views.openPage("usage");
  assert.equal(fromAnswer.views.pageBackLabel(), "Back");
});

test("while the list is open the session's hash isn't written; a session picked leaves the list for it", () => {
  const h = harness({ hash: "#/pages", selected: ID, list: true });
  h.views.setSessionHash(null);
  assert.equal(h.calls.some((c) => c[0] === "replace"), false);
  assert.equal(h.location.hash, "#/pages");
  assert.equal(h.views.pagesAreaOpen(), true);
  h.views.setSessionHash(OTHER);
  assert.equal(h.location.hash, `#/s/${OTHER}`);
  assert.equal(h.views.pagesAreaOpen(), false);
});

test("All sessions -> pill -> list -> Back keeps All sessions' own Back a history.back()", () => {
  const h = harness({ hash: `#/s/${ID}`, selected: ID, list: true });
  h.views.openAllView();
  h.listeners.hashchange();
  h.views.openPagesList();
  h.listeners.hashchange();
  h.views.closePagesList();
  go(h, "#/sessions");
  h.views.closeAllView();
  assert.deepEqual(h.calls.filter(([kind]) => kind === "back"), [["back"], ["back"]]);
});

test("the pill on a page opened from the list goes back to that list's entry (no second #/pages)", () => {
  const h = harness({ hash: `#/s/${ID}`, selected: ID, list: true });
  h.views.openPagesList();
  h.listeners.hashchange();
  h.views.openPage("usage");
  h.listeners.hashchange();
  h.views.openPagesList();
  assert.deepEqual(h.calls.filter(([kind]) => kind === "back"), [["back"]]);
  assert.equal(h.location.hash, "#/p/usage", "no push: history.back() leaves for the list");
});

test("a page with no history put on the list: the list's Back then leaves for the session's hash, not a dead history.back()", () => {
  const h = harness({ hash: `#/s/${ID}`, selected: ID, list: true });
  h.views.openPagesList(); // pushed
  h.listeners.hashchange();
  go(h, "#/p/usage"); // a typed hash: not pushed by the page
  h.views.closePage();
  assert.equal(h.location.hash, "#/pages");
  h.views.closePagesList();
  assert.equal(h.calls.some(([kind]) => kind === "back"), false);
  assert.equal(h.location.hash, `#/s/${ID}`);
});
