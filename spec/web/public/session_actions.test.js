// The page's whole-session actions (session_actions.js) over stand-in
// hooks: Delete, Stop, Continue, Archive and its Undo, a gone session.
// The refusals' and toasts' words are format.js' and chains.js'.
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createSessionActions } from "../../../lib/samagotchi/web/public/session_actions.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

function failure(status, code = null, message = "boom", body = null) {
  return Object.assign(new Error(message), { status, code, body });
}

// +api+: overrides of the data.js calls (each records its call in +calls+).
// +displaced+: what fillOpener returns (a draft from another session it replaced, or null).
// +holds+: what the worker answers GET …/holds with; +sheet+ stands in for
// stop_sheet.js' sheet (the default opens when there is something, as it does).
function harness({ list = [{ id: "s1aaaaaaaa" }], open = "s1aaaaaaaa", api = {}, confirms = true, eventsLive = true,
                  displaced = null, holds = [], sheet = null, deleteSheet = null, doc = null } = {}) {
  // world.state reads the page's session store (Stop writes its status there).
  const store = createSessionStore({ initial: { status: "running" } });
  const world = { selected: open, sessions: list, get state() { return store.current; } };
  const log = [];
  const calls = [];
  const toasts = [];
  const alerts = [];
  const opened = [];
  // Each confirm's text; +confirms+ is the answer, or one per confirm in turn.
  const asked = [];
  const wrap = (name, fallback) => async (...args) => {
    calls.push([name, ...args]);
    return (api[name] || fallback)(...args);
  };
  // The bar's redraw, registered as app.js registers it (a touch for the
  // continue in-flight set).
  store.on("infoBar", () => log.push(`infoBar ${[...actions.continuing].join(",")}`));
  const actions = createSessionActions({
    selected: () => world.selected,
    store,
    sessions: () => world.sessions,
    setSessions: (next) => { world.sessions = next; },
    api: {
      deleteSession: wrap("deleteSession", async () => ({})),
      stopSession: wrap("stopSession", async () => ({})),
      continueSession: wrap("continueSession", async () => ({ id: "s2bbbbbbbb", continues: "s1aaaaaaaa" })),
      archiveSession: wrap("archiveSession", async (id) => ({ archived: [id], stopped: [] })),
      unarchiveSession: wrap("unarchiveSession", async (id) => ({ unarchived: [id] })),
      sessionHolds: wrap("sessionHolds", async () => ({ holds })),
      stopSessionHolds: wrap("stopSessionHolds", async () => ({ status: "stopped", stopped: {} })),
      deletePlan: wrap("deletePlan", async () => ({ chained: false, link: {} })),
      deleteChain: wrap("deleteChain", async () => ({})),
    },
    eventsLive: () => eventsLive,
    refresh: () => log.push("refresh"),
    select: async (id) => { log.push(`select ${id}`); world.selected = id; },
    clearSelection: () => { log.push("clearSelection"); world.selected = null; },
    showNotice: (text) => log.push(`notice ${text}`),
    toast: (text, action = null, options = {}) => toasts.push({ text, action, options }),
    addCreatedSession: (created) => log.push(`created ${created.id}`),
    fillOpener: (created, continuedId) => { log.push(`opener ${created.id} from ${continuedId}`); return displaced; },
    restoreDraft: (draft, opener) => log.push(["restoreDraft", draft, opener]),
    closeLiveStream: () => log.push("closeLiveStream"),
    workerGone: (id) => log.push(`workerGone ${id} stopping=${actions.stoppingId()}`),
    alert: (text) => alerts.push(text),
    confirm: (text) => { asked.push(text); return Array.isArray(confirms) ? confirms.shift() : confirms; },
    stopSheet: sheet ?? { open: (id, held) => { opened.push([id, held]); return Array.isArray(held) && held.length > 0; } },
    deleteSheet,
    doc,
  });
  return { actions, world, log, calls, toasts, alerts, opened, asked };
}

// The 409 a delete or an archive answers while background tasks it would
// take still run (SessionManager::RunningTasks).
const TASKS = { running: [{ session_id: "s1aaaaaaaa", id: "20261120-3f9a2c1d", command: "npm run dev" },
                          { session_id: "s1aaaaaaaa", id: "20261120-0badf00d", command: "rspec" }],
                unverified: [], unreadable: [] };
const tasksRunning = (op) => failure(409, "tasks_running", "background tasks it started are still running: npm run dev, rspec",
                                      { error: "tasks_running", op, tasks: TASKS });
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const STOPPED = { tasks_stopped: TASKS.running, tasks_not_stopped: [] };

// The delete sheet's shell, as delete_sheet.js createDeleteSheet's: each
// host it hands out records what it showed and where it was anchored.
function fakeSheet() {
  const sheet = { hosts: [] };
  sheet.host = (anchor, id) => {
    const host = { anchor, id, back: false, shown: [], closed: 0, flow: null };
    host.show = (tpl) => host.shown.push(markupOf(tpl));
    host.close = () => { host.closed += 1; };
    host.wire = (flow) => { host.flow = flow; };
    sheet.hosts.push(host);
    return host;
  };
  return sheet;
}

// A document with ⋯ and the cards' archive buttons (+cards+: their ids; a
// box unless listed in +hidden+).
function fakeDoc({ cards = [], hidden = [] } = {}) {
  const more = { id: "infoMoreBtn", getClientRects: () => [1] };
  const arch = cards.map((id) => ({ dataset: { arch: id }, getClientRects: () => (hidden.includes(id) ? [] : [1]) }));
  return {
    more, arch,
    querySelector: (sel) => (sel === "#infoMoreBtn" ? more : null),
    querySelectorAll: (sel) => arch.filter((el) => sel === `[data-arch="${el.dataset.arch}"]`),
  };
}

const plan = (link = {}) => ({ chained: false, session_id: "s1aaaaaaaa",
  link: { digest: "d0", delegates: { delete: [], leave: [] }, tasks: { running: [], unverified: [], unreadable: [] }, worker: null,
          refusal: null, ...link } });

test("confirmDelete: no browser confirm: the sheet opens at the card's ✕ (else ⋯), and its tap deletes; the list drops it", async () => {
  const sheet = fakeSheet();
  const doc = fakeDoc();
  const h = harness({ list: [{ id: "s1aaaaaaaa" }, { id: "s2bbbbbbbb" }], sheet: undefined, deleteSheet: sheet, doc,
                      api: { deletePlan: async () => plan(), deleteSession: async () => ({ deleted: ["s1aaaaaaaa"] }) } });
  const card = { card: true };
  h.actions.confirmDelete("s1aaaaaaaa", { anchor: card });
  h.actions.confirmDelete("s2bbbbbbbb");
  assert.deepEqual(sheet.hosts.map((x) => x.anchor), [card, doc.more]);
  await tick();
  sheet.hosts[0].flow.act("this");
  await tick();
  assert.deepEqual(h.calls.filter(([n]) => n === "deleteSession"), [["deleteSession", "s1aaaaaaaa", { expect: "d0" }]]);
  assert.deepEqual(h.world.sessions.map((s) => s.id), ["s2bbbbbbbb"]);
  assert.deepEqual(h.log, ["clearSelection"]);
  assert.deepEqual(h.toasts.map((t) => t.text), ["Deleted s1aaaaaa"]);
  assert.deepEqual([h.asked, h.alerts], [[], []]);
});

test("confirmDelete: running tasks are one sheet and one tap: the named ids go with the delete, the toast says what stopped", async () => {
  const sheet = fakeSheet();
  const h = harness({ deleteSheet: sheet, doc: fakeDoc(),
                      api: { deletePlan: async () => plan({ tasks: TASKS }), deleteSession: async () => ({ deleted: ["s1aaaaaaaa"], ...STOPPED }) } });
  h.actions.confirmDelete("s1aaaaaaaa");
  await tick();
  assert.match(sheet.hosts[0].shown.at(-1), />Stop them and delete</);
  sheet.hosts[0].flow.act("this");
  await tick();
  assert.deepEqual(h.calls.at(-1), ["deleteSession", "s1aaaaaaaa",
                                    { expect: "d0", stopTasks: true, tasks: ["20261120-3f9a2c1d", "20261120-0badf00d"] }]);
  assert.deepEqual(h.toasts.map((t) => t.text), ["Deleted s1aaaaaa · stopped 2 background tasks"]);
  assert.deepEqual([h.asked, h.alerts], [[], []]);
});

test("confirmDelete: a terminal's one-turn run is the plan's refusal in the sheet: no alert, no delete", async () => {
  const sheet = fakeSheet();
  const h = harness({ list: [{ id: "s1aaaaaaaa", owner: "tui" }], deleteSheet: sheet, doc: fakeDoc(),
                      api: { deletePlan: async () => plan({ refusal: { reason: "owned_by_tui", message: "session s1aaaaaaaa is busy; let it finish first" } }) } });
  h.actions.confirmDelete("s1aaaaaaaa");
  await tick();
  assert.match(sheet.hosts[0].shown.at(-1), /Can't delete s1aaaaaa now/);
  assert.deepEqual(h.calls.map(([n]) => n), ["deletePlan"]);
  assert.deepEqual(h.alerts, []);
});

test("confirmDelete: the sheet closed while its tap runs: a refusal that comes after is a sticky toast", async () => {
  const sheet = fakeSheet();
  let reject;
  const h = harness({ deleteSheet: sheet, doc: fakeDoc(),
                      api: { deletePlan: async () => plan(), deleteSession: () => new Promise((_resolve, no) => { reject = no; }) } });
  h.actions.confirmDelete("s1aaaaaaaa");
  await tick();
  const host = sheet.hosts[0];
  host.live = () => host.closed === 0;
  host.flow.act("this");
  host.close();
  reject(failure(409, "tui_owned", "a terminal chi has it open"));
  await tick();
  assert.deepEqual(h.toasts.map((t) => [t.text, t.options.sticky]), [["Can't delete s1aaaaaa: a terminal chi has it open", true]]);
  assert.deepEqual(h.world.sessions, [{ id: "s1aaaaaaaa" }]);
});

test("deleteIn: the More panel's Delete always takes the panel as its host, for any session", async () => {
  const h = harness({ api: { deletePlan: async () => plan() } });
  const host = fakeSheet().host(null, "s1aaaaaaaa");
  assert.equal(h.actions.deleteIn("s1aaaaaaaa", host), true);
  assert.equal(h.actions.deleteIn("not-in-the-list", fakeSheet().host(null, "x")), true);
  await tick();
  assert.match(host.shown.at(-1), /data-act="del:this">Delete</);
});

test("setArchived: nothing in the way is one tap, no sheet, the Undo toast", async () => {
  const sheet = fakeSheet();
  const h = harness({ deleteSheet: sheet, doc: fakeDoc({ cards: ["s1aaaaaaaa"] }) });
  await h.actions.setArchived("s1aaaaaaaa", true);
  assert.deepEqual(sheet.hosts, []);
  assert.deepEqual(h.toasts.map((t) => [t.text, t.action?.label]), [["Archived s1aaaaaa", "Undo"]]);
});

test("setArchived: a 409 tasks_running opens the sheet at the card's archive button; its tap archives with the named ids, then Undo", async () => {
  let first = true;
  const sheet = fakeSheet();
  const doc = fakeDoc({ cards: ["s1aaaaaaaa", "s1aaaaaaaa"], hidden: [] });
  doc.arch[0].getClientRects = () => []; // the strip's, hidden
  const h = harness({ deleteSheet: sheet, doc, api: { archiveSession: async (id) => {
    if (first) { first = false; throw tasksRunning("archive"); }
    return { archived: [id], stopped: [], ...STOPPED, tasks_not_stopped: [{ session_id: "s1aaaaaaaa", id: "x-0badf00d", command: "rspec" }] };
  } } });
  await h.actions.setArchived("s1aaaaaaaa", true);
  assert.equal(sheet.hosts[0].anchor, doc.arch[1]);
  assert.match(sheet.hosts[0].shown.at(-1), />Stop them and archive</);
  assert.deepEqual(h.toasts, []);
  sheet.hosts[0].flow.act("archive");
  await tick();
  assert.deepEqual(h.calls, [["archiveSession", "s1aaaaaaaa"],
                             ["archiveSession", "s1aaaaaaaa", { stopTasks: true, tasks: ["20261120-3f9a2c1d", "20261120-0badf00d"] }]]);
  assert.deepEqual(h.toasts.map((t) => t.text), ["Archived s1aaaaaa · stopped 2 background tasks · 1 not stopped: rspec"]);
  assert.equal(h.toasts[0].action.label, "Undo");
  assert.deepEqual([h.asked, h.alerts], [[], []]);
});

test("toggleArchiveSelected: the open session's archive sheet opens at ⋯", async () => {
  const sheet = fakeSheet();
  const doc = fakeDoc({ cards: ["s1aaaaaaaa"] });
  const h = harness({ deleteSheet: sheet, doc, api: { archiveSession: async () => { throw tasksRunning("archive"); } } });
  h.actions.toggleArchiveSelected();
  await tick();
  assert.equal(sheet.hosts[0].anchor, doc.more);
});

test("setArchived: any other refusal is the sheet's Can't archive; with no sheet, a sticky toast (never an alert)", async () => {
  const sheet = fakeSheet();
  const busy = failure(409, "busy", "a prompt is queued, which a resume would run; let it run first", { reason: "queued" });
  const h = harness({ deleteSheet: sheet, doc: fakeDoc(), api: { archiveSession: async () => { throw busy; } } });
  await h.actions.setArchived("s1aaaaaaaa", true);
  assert.match(sheet.hosts[0].shown.at(-1), /Can't archive s1aaaaaa now/);
  const bare = harness({ api: { archiveSession: async () => { throw failure(500, null, "disk full"); } } });
  await bare.actions.setArchived("s1aaaaaaaa", true);
  assert.deepEqual(bare.toasts.map((t) => [t.text, t.options.sticky]), [["Can't archive s1aaaaaa: disk full", true]]);
  assert.deepEqual([h.alerts, bare.alerts], [[], []]);
});

test("archiveOne: a batch's archive never retries; the 409 is its answer", async () => {
  const h = harness({ api: { archiveSession: async () => { throw tasksRunning("archive"); } } });
  const answer = await h.actions.archiveOne("s1aaaaaaaa", true);

  assert.equal(answer.ok, false);
  assert.equal(answer.error.code, "tasks_running");
  assert.deepEqual(h.calls, [["archiveSession", "s1aaaaaaaa"]]);
  assert.deepEqual(h.asked, []);
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
  // The status redraws the bar (the store); workerGone (the page's) the rest.
  assert.deepEqual(h.log, ["closeLiveStream", "infoBar ", "workerGone s1aaaaaaaa stopping=s1aaaaaaaa", "refresh"]);
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

test("archiveOne: archiving a tree that holds the open session is a stop for its stream when the server stopped it", async () => {
  const list = [{ id: "parent" }, { id: "s1aaaaaaaa", parent_id: "parent" }];
  const h = harness({ list, api: { archiveSession: async () => ({ archived: ["parent", "s1aaaaaaaa"], stopped: ["s1aaaaaaaa"] }) } });
  const answer = await h.actions.archiveOne("parent", true);
  assert.equal(answer.ok, true);
  assert.deepEqual(h.log, ["closeLiveStream", "infoBar ", "workerGone s1aaaaaaaa stopping=s1aaaaaaaa"]);
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

