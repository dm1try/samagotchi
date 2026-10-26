// The page's whole-session actions (session_actions.js) over stand-in
// hooks: Delete, Stop, Continue, Archive and its Undo, a gone session.
// The refusals' and toasts' words are format.js' and chains.js'.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createSessionActions } from "../../../lib/samagotchi/web/public/session_actions.js";

function failure(status, code = null, message = "boom", body = null) {
  return Object.assign(new Error(message), { status, code, body });
}

// +api+: overrides of the data.js calls (each records its call in +calls+).
// +displaced+: what fillOpener returns (a draft from another session it replaced, or null).
// +holds+: what the worker answers GET …/holds with; +sheet+ stands in for
// stop_sheet.js' sheet (the default opens when there is something, as it does).
function harness({ list = [{ id: "s1aaaaaaaa" }], open = "s1aaaaaaaa", api = {}, confirms = true, eventsLive = true,
                  displaced = null, holds = [], sheet = null } = {}) {
  const world = { selected: open, sessions: list, state: { status: "running" } };
  const log = [];
  const calls = [];
  const toasts = [];
  const alerts = [];
  const opened = [];
  const wrap = (name, fallback) => async (...args) => {
    calls.push([name, ...args]);
    return (api[name] || fallback)(...args);
  };
  const actions = createSessionActions({
    selected: () => world.selected,
    state: () => world.state,
    sessions: () => world.sessions,
    setSessions: (next) => { world.sessions = next; },
    api: {
      deleteSession: wrap("deleteSession", async () => ({})),
      stopSession: wrap("stopSession", async () => ({})),
      continueSession: wrap("continueSession", async () => ({ id: "s2bbbbbbbb", continues: "s1aaaaaaaa" })),
      archiveSession: wrap("archiveSession", async (id) => ({ archived: [id], stopped: [] })),
      unarchiveSession: wrap("unarchiveSession", async (id) => ({ unarchived: [id] })),
      startReview: wrap("startReview", async () => ({ id: "s3cccccccc", review: { from: "s1aaaaaaaa" } })),
      sessionHolds: wrap("sessionHolds", async () => ({ holds })),
      stopSessionHolds: wrap("stopSessionHolds", async () => ({ status: "stopped", stopped: {} })),
    },
    eventsLive: () => eventsLive,
    refresh: () => log.push("refresh"),
    lists: { render: () => log.push("render") },
    select: async (id) => { log.push(`select ${id}`); world.selected = id; },
    clearSelection: () => { log.push("clearSelection"); world.selected = null; },
    showNotice: (text) => log.push(`notice ${text}`),
    updateInfoBar: () => log.push(`infoBar ${[...actions.continuing].join(",")}`),
    toast: (text, action = null, options = {}) => toasts.push({ text, action, options }),
    addCreatedSession: (created) => log.push(`created ${created.id}`),
    fillOpener: (created, continuedId) => { log.push(`opener ${created.id} from ${continuedId}`); return displaced; },
    restoreDraft: (draft, opener) => log.push(["restoreDraft", draft, opener]),
    closeLiveStream: () => log.push("closeLiveStream"),
    workerGone: (id) => log.push(`workerGone ${id} stopping=${actions.stoppingId()}`),
    alert: (text) => alerts.push(text),
    confirm: () => confirms,
    stopSheet: sheet ?? { open: (id, held) => { opened.push([id, held]); return Array.isArray(held) && held.length > 0; } },
  });
  return { actions, world, log, calls, toasts, alerts, opened };
}

test("confirmDelete: after a confirm the list drops it, and the open session goes to the start page", async () => {
  const h = harness({ list: [{ id: "s1aaaaaaaa" }, { id: "s2bbbbbbbb" }] });
  await h.actions.confirmDelete("s1aaaaaaaa");
  assert.deepEqual(h.calls, [["deleteSession", "s1aaaaaaaa"]]);
  assert.deepEqual(h.world.sessions.map((s) => s.id), ["s2bbbbbbbb"]);
  assert.deepEqual(h.log, ["clearSelection", "render"]);
});

test("confirmDelete: a terminal's session is refused before the confirm; no confirm, no request", async () => {
  const tui = harness({ list: [{ id: "s1aaaaaaaa", owner: "tui" }] });
  await tui.actions.confirmDelete("s1aaaaaaaa");
  assert.deepEqual(tui.alerts, ["Session s1aaaaaa is open in a terminal chi; close it there first."]);
  assert.deepEqual(tui.calls, []);
  const no = harness({ confirms: false });
  await no.actions.confirmDelete("s1aaaaaaaa");
  assert.deepEqual(no.calls, []);
});

test("confirmDelete: a failed delete says why and keeps the list; without the hub's stream it refetches", async () => {
  const h = harness({ eventsLive: false, api: { deleteSession: async () => { throw failure(409, "owned_by_tui", "attached"); } } });
  await h.actions.confirmDelete("s1aaaaaaaa");
  assert.deepEqual(h.alerts, ["Could not delete session s1aaaaaa: attached"]);
  assert.deepEqual(h.log, ["refresh"]);
  assert.equal(h.world.sessions.length, 1);
});

test("leaveGoneSession: only the open session goes back to the start page, with its notice", () => {
  const h = harness();
  h.actions.leaveGoneSession("other", "deleted");
  assert.deepEqual(h.log, []);
  h.actions.leaveGoneSession("s1aaaaaaaa", "deleted");
  assert.equal(h.log[0], "clearSelection");
  assert.match(h.log[1], /^notice .*s1aaaaaa/);
});

test("stopSelected: the stream's end is a stop while the request runs; the open session's worker is gone at once", async () => {
  let release;
  const h = harness({ eventsLive: false, api: { stopSession: () => new Promise((resolve) => { release = resolve; }) } });
  const stopping = h.actions.stopSelected();
  await new Promise((resolve) => setImmediate(resolve)); // the holds check comes first
  assert.equal(h.actions.stoppingId(), "s1aaaaaaaa");
  release({});
  await stopping;
  assert.equal(h.world.state.status, "stopped");
  assert.deepEqual(h.log, ["closeLiveStream", "workerGone s1aaaaaaaa stopping=s1aaaaaaaa", "refresh"]);
  assert.equal(h.actions.stoppingId(), null);
});

test("Stop asks the worker what still runs first; with nothing it is the confirm and one stop", async () => {
  const h = harness();
  await h.actions.stopSelected();

  assert.deepEqual(h.calls, [["sessionHolds", "s1aaaaaaaa"], ["stopSession", "s1aaaaaaaa"]]);
  assert.deepEqual(h.opened, [["s1aaaaaaaa", []]]);
});

test("a second Stop while the holds read is under way asks nothing more: one confirm, one stop", async () => {
  let answer;
  const pending = new Promise((resolve) => { answer = resolve; });
  const h = harness({ api: { sessionHolds: () => pending } });
  const first = h.actions.stopSelected();
  const second = h.actions.stopSelected();
  answer({ holds: [] });
  await Promise.all([first, second]);

  assert.deepEqual(h.calls, [["sessionHolds", "s1aaaaaaaa"], ["stopSession", "s1aaaaaaaa"]]);
  assert.deepEqual(h.opened, [["s1aaaaaaaa", []]], "one sheet-or-confirm");
  await h.actions.stopSelected();
  assert.equal(h.calls.filter(([name]) => name === "sessionHolds").length, 2, "a later Stop asks again");
});

test("with something stoppable the sheet decides: no confirm, nothing stopped yet", async () => {
  const held = [{ kind: "background_tasks", items: [{ id: "t1", label: "npm test", detail: "3m" }] }];
  const h = harness({ holds: held });
  await h.actions.stopSelected();

  assert.deepEqual(h.calls, [["sessionHolds", "s1aaaaaaaa"]]);
  assert.deepEqual(h.opened, [["s1aaaaaaaa", held]]);
});

test("a worker that can't answer what it holds is today's one-tap stop", async () => {
  const h = harness({ api: { sessionHolds: async () => { throw failure(503, "not_live", "no live bridge"); } } });
  await h.actions.stopSelected();

  assert.deepEqual(h.calls, [["sessionHolds", "s1aaaaaaaa"], ["stopSession", "s1aaaaaaaa"]]);
  assert.deepEqual(h.toasts, []);
});

test("the sheet's Stop all: the worker's stop-all step, then the stop; a failed step is a sticky toast and stops anyway", async () => {
  const h = harness();
  await h.actions.stopSelected("s1aaaaaaaa", { stopHolds: true });
  assert.deepEqual(h.calls, [["stopSessionHolds", "s1aaaaaaaa"], ["stopSession", "s1aaaaaaaa"]]);

  const failed = harness({ api: { stopSessionHolds: async () => { throw failure(502, "bridge_error", "the worker refused"); } } });
  await failed.actions.stopSelected("s1aaaaaaaa", { stopHolds: true });
  assert.deepEqual(failed.calls, [["stopSessionHolds", "s1aaaaaaaa"], ["stopSession", "s1aaaaaaaa"]]);
  assert.match(failed.toasts[0].text, /Can't stop what the session runs: the worker refused — stopping the session anyway/);
  assert.equal(failed.toasts[0].options.sticky, true);
});

test("stopSelected: a refusal is a sticky toast; a switch meanwhile leaves the other session alone", async () => {
  const refused = harness({ api: { stopSession: async () => { throw failure(409, "owned_by_tui", "a terminal holds it"); } } });
  await refused.actions.stopSelected();
  assert.equal(refused.toasts.length, 1);
  assert.match(refused.toasts[0].text, /stop s1aaaaaa/);
  assert.equal(refused.toasts[0].options.sticky, true);
  assert.equal(refused.actions.stoppingId(), null);
  const switched = harness({ api: { stopSession: async () => { switched.world.selected = "s9"; return {}; } } });
  await switched.actions.stopSelected();
  assert.deepEqual(switched.log, []);
});

test("continueSelected: the next link opens with its opener; the previous one is marked archived", async () => {
  const h = harness();
  await h.actions.continueSelected();
  assert.deepEqual(h.calls, [["continueSession", "s1aaaaaaaa"]]);
  assert.equal(h.world.sessions[0].archived, true);
  assert.deepEqual(h.log, [
    "infoBar s1aaaaaaaa", "created s2bbbbbbbb", "select s2bbbbbbbb", "opener s2bbbbbbbb from s1aaaaaaaa", "infoBar ",
  ]);
  assert.equal(h.toasts.length, 1);
  assert.equal(h.toasts[0].action, null);
  assert.equal(h.toasts[0].options.sticky, false);
});

test("continueSelected: a draft from another session gave way to the opener: a sticky toast's Restore draft brings it back", async () => {
  const h = harness({ displaced: "my shell setup" });
  await h.actions.continueSelected();
  assert.equal(h.toasts.length, 1);
  const { action, options } = h.toasts[0];
  assert.equal(action.label, "Restore draft");
  assert.equal(options.sticky, true);
  action.run();
  assert.deepEqual(h.log.at(-1), ["restoreDraft", "my shell setup", "Continue where we left off."]);
});

test("continueSelected: a model fallback's warning stays sticky with no draft displaced", async () => {
  const h = harness({ api: { continueSession: async () => ({ id: "s2bbbbbbbb", continues: "s1aaaaaaaa", model_warning: "fell back" }) } });
  await h.actions.continueSelected();
  assert.equal(h.toasts[0].action, null);
  assert.equal(h.toasts[0].options.sticky, true);
});

test("continueSelected: a switch meanwhile offers Open instead; one continue per session at a time", async () => {
  let release;
  const h = harness({ api: { continueSession: () => new Promise((resolve) => { release = resolve; }) } });
  const first = h.actions.continueSelected();
  await h.actions.continueSelected(); // the same session: nothing
  assert.equal(h.calls.length, 1);
  h.world.selected = "other";
  release({ id: "s2bbbbbbbb", model_warning: "fell back" });
  await first;
  assert.equal(h.toasts[0].action.label, "Open");
  assert.equal(h.toasts[0].options.sticky, true);
  assert.ok(!h.log.includes("select s2bbbbbbbb"));
  await h.toasts[0].action.run();
  assert.equal(h.world.selected, "s2bbbbbbbb");
});

test("continueSelected: continued already opens that next link; other refusals are sticky toasts", async () => {
  const already = harness({
    api: { continueSession: async () => { throw failure(409, "continued", "continued", { next_id: "s3cccccccc" }); } },
  });
  await already.actions.continueSelected();
  assert.equal(already.world.selected, "s3cccccccc");
  assert.equal(already.toasts[0].text, "s1aaaaaa is continued already: opened s3cccccc");
  const other = harness({ api: { continueSession: async () => { throw failure(500, null, "boom"); } } });
  await other.actions.continueSelected();
  assert.match(other.toasts[0].text, /^Can't continue s1aaaaaa: /);
  assert.equal(other.toasts[0].options.sticky, true);
  assert.equal(other.actions.continuing.size, 0);
});

test("setArchived: the ids flip at once, a toast offers Undo, and Undo's own toast offers none", async () => {
  const h = harness({ list: [{ id: "s1aaaaaaaa" }, { id: "kid" }],
                      api: { archiveSession: async () => ({ archived: ["s1aaaaaaaa", "kid"], stopped: [] }) } });
  await h.actions.setArchived("s1aaaaaaaa", true);
  assert.deepEqual(h.world.sessions.map((s) => s.archived), [true, true]);
  assert.equal(h.toasts[0].text, "Archived s1aaaaaa");
  assert.equal(h.toasts[0].action.label, "Undo");
  await h.toasts[0].action.run();
  assert.deepEqual(h.calls.at(-1), ["unarchiveSession", "s1aaaaaaaa"]);
  assert.equal(h.toasts[1].text, "Unarchived s1aaaaaa");
  assert.equal(h.toasts[1].action, null);
});

test("setArchived: a failure is an alert and nothing else", async () => {
  const h = harness({ api: { archiveSession: async () => { throw failure(500, null, "disk full"); } } });
  await h.actions.setArchived("s1aaaaaaaa", true);
  assert.deepEqual(h.alerts, ["Could not archive session s1aaaaaa: disk full"]);
  assert.deepEqual(h.log, []);
  assert.deepEqual(h.toasts, []);
});

test("archiveOne: archiving a tree that holds the open session is a stop for its stream when the server stopped it", async () => {
  const list = [{ id: "parent" }, { id: "s1aaaaaaaa", parent_id: "parent" }];
  const h = harness({ list, api: { archiveSession: async () => ({ archived: ["parent", "s1aaaaaaaa"], stopped: ["s1aaaaaaaa"] }) } });
  const answer = await h.actions.archiveOne("parent", true);
  assert.equal(answer.ok, true);
  assert.deepEqual(h.log, ["closeLiveStream", "workerGone s1aaaaaaaa stopping=s1aaaaaaaa"]);
  assert.equal(h.actions.stoppingId(), null);
  const failed = harness({ api: { unarchiveSession: async () => { throw failure(404); } } });
  const refused = await failed.actions.archiveOne("s1aaaaaaaa", false);
  assert.equal(refused.ok, false);
  assert.equal(refused.error.status, 404);
});

test("toggleArchiveSelected: archives the open session, or unarchives an archived one", async () => {
  const h = harness({ list: [{ id: "s1aaaaaaaa", archived: true }] });
  h.actions.toggleArchiveSelected();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(h.calls, [["unarchiveSession", "s1aaaaaaaa"]]);
  const none = harness({ open: null });
  none.actions.toggleArchiveSelected();
  assert.deepEqual(none.calls, []);
});

test("reviewSelected: the created review session, opened; a refusal goes to onError when it says it, else a sticky toast", async () => {
  const h = harness();
  const created = await h.actions.reviewSelected();
  assert.equal(created.id, "s3cccccccc");
  assert.equal(h.world.selected, "s3cccccccc");
  const refused = harness({ api: { startReview: async () => { throw failure(400, "invalid_review", "the folder is gone"); } } });
  const said = [];
  assert.equal(await refused.actions.reviewSelected({ onError: (text) => said.push(text) }), null);
  assert.deepEqual(said, ["Can't start a review of s1aaaaaa: the folder is gone"]);
  assert.deepEqual(refused.toasts, []);
  assert.equal(await refused.actions.reviewSelected({ onError: () => false }), null);
  assert.equal(refused.toasts.length, 1);
  assert.equal(refused.toasts[0].options.sticky, true);
  assert.equal(refused.actions.reviewing.size, 0);
});
