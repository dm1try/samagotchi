// The page's views by hash (views.js): All sessions at #/sessions opened,
// closed and left, the session's own hash, and what a hash change selects.
// Moved out of app.js as it was: these pin its behaviour with stand-ins.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createViews } from "../../../lib/samagotchi/web/public/views.js";

const ID = "d4c5c3af-a814-48dd-a59c-fffa4bc0b094";
const OTHER = "0a1b2c3d-1111-2222-3333-444455556666";

function harness({ hash = "", participant = null, selected = null, events = true } = {}) {
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
  document.body.innerHTML = '<button id="stripStatus"></button><input id="filter"><div id="topStrip"></div>';
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
  });
  return { views, calls, location, listeners, store, lists };
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
