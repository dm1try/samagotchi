// A mixed cache around the delete sheet (docs/internals/web-frontend.md, New
// exports go in new modules): a proxy that ignores no-cache may serve 0.182.0's
// delete_sheet.js beside this session_actions.js, or the reverse. Each pair is
// loaded from a copy of the page's modules with the old file put back
// (fixtures/v0.182.0/, the released files), so the real modules meet. Neither
// direction throws, and a delete or archive that didn't happen says so.
// Goes at the next release, with the hooks it covers (marked "kept for an
// older cached …" in session_actions.js and delete_sheet.js).
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

const here = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(here, "../../../lib/samagotchi/web/public");
const OLD = join(here, "fixtures/v0.182.0");

// The page's modules with +oldFile+ as 0.182.0 shipped it; its session_actions.js.
async function mixedPage(oldFile) {
  const dir = mkdtempSync(join(tmpdir(), "chi-mixed-cache-"));
  test.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(PUBLIC, dir, { recursive: true });
  cpSync(join(OLD, oldFile), join(dir, oldFile));
  return import(pathToFileURL(join(dir, "session_actions.js")).href);
}

const S = "ab12cd34-0000-0000-0000-000000000001";
const A = "1a2b3c4d-0000-0000-0000-000000000002";
const B = "3f2a91c0-0000-0000-0000-000000000003";
const TASKS = { running: [{ session_id: S, id: "20261120-3f9a2c1d", command: "npm run dev" }], unverified: [], unreadable: [] };
const failure = (status, code, message, body = null) => Object.assign(new Error(message), { status, code, body });
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

// A card shell's host as createDeleteSheet's: live until closed.
function fakeSheet() {
  const sheet = { hosts: [], openFor: () => null, isOpen: () => false };
  sheet.host = (anchor, id) => {
    const host = { anchor, id, back: false, shown: [], closed: 0, flow: null };
    host.live = () => host.closed === 0;
    host.show = (tpl) => host.shown.push(markupOf(tpl));
    host.close = () => { host.closed += 1; };
    host.wire = (flow) => { host.flow = flow; };
    sheet.hosts.push(host);
    return host;
  };
  return sheet;
}

function harness(createSessionActions, { list, api = {} }) {
  const world = { selected: null, sessions: list };
  const toasts = [];
  const alerts = [];
  const sheet = fakeSheet();
  const more = { id: "infoMoreBtn", getClientRects: () => [1] };
  const actions = createSessionActions({
    selected: () => world.selected,
    store: createSessionStore({ initial: { status: "running" } }),
    sessions: () => world.sessions,
    setSessions: (next) => { world.sessions = next; },
    api: {
      deletePlan: async () => ({ chained: false, session_id: S, link: { digest: "d0" } }),
      deleteSession: async () => ({ deleted: [S] }),
      deleteChain: async () => ({}),
      archiveSession: async (id) => ({ archived: [id], stopped: [] }),
      unarchiveSession: async (id) => ({ unarchived: [id] }),
      stopSession: async () => ({}),
      ...api,
    },
    eventsLive: () => true,
    refresh: () => {},
    select: async (id) => { world.selected = id; },
    clearSelection: () => { world.selected = null; },
    showNotice: () => {},
    toast: (text, action = null, options = {}) => toasts.push({ text, action, options }),
    addCreatedSession: () => {},
    fillOpener: () => null,
    restoreDraft: () => {},
    closeLiveStream: () => {},
    workerGone: () => {},
    alert: (text) => alerts.push(text),
    confirm: () => true,
    deleteSheet: sheet,
    doc: { querySelector: (sel) => (sel === "#infoMoreBtn" ? more : null), querySelectorAll: () => [] },
  });
  return { actions, world, toasts, alerts, sheet };
}

test("0.182.0's delete_sheet.js with this session_actions.js: a session in no chain is a sticky toast, not a TypeError", async () => {
  const { createSessionActions } = await mixedPage("delete_sheet.js");
  const h = harness(createSessionActions, { list: [{ id: S }] });
  h.actions.confirmDelete(S);
  await tick();
  assert.equal(h.sheet.hosts[0].closed, 1);
  assert.equal(h.toasts.length, 1);
  assert.equal(h.toasts[0].options.sticky, true);
  assert.match(h.toasts[0].text, /^Can't delete ab12cd34: /);
  assert.deepEqual(h.world.sessions, [{ id: S }]);
});

test("0.182.0's delete_sheet.js with this session_actions.js: a plan that can't be read closes the sheet and says why", async () => {
  const { createSessionActions } = await mixedPage("delete_sheet.js");
  const h = harness(createSessionActions, { list: [{ id: S }], api: { deletePlan: async () => { throw failure(500, null, "disk full"); } } });
  h.actions.confirmDelete(S);
  await tick();
  assert.deepEqual(h.toasts.map((t) => [t.text, t.options.sticky]), [["Can't delete ab12cd34: disk full", true]]);
});

test("0.182.0's delete_sheet.js with this session_actions.js: archive's 409 says Can't archive, nothing thrown", async () => {
  const { createSessionActions } = await mixedPage("delete_sheet.js");
  const refusal = failure(409, "tasks_running", "background tasks it started are still running: npm run dev",
                          { error: "tasks_running", tasks: TASKS, sessions: 1 });
  const h = harness(createSessionActions, { list: [{ id: S }], api: { archiveSession: async () => { throw refusal; } } });
  h.world.selected = S;
  await h.actions.toggleArchiveSelected();
  await tick();
  assert.deepEqual(h.toasts.map((t) => [t.text, t.options.sticky]),
                   [["Can't archive ab12cd34: background tasks it started are still running: npm run dev", true]]);
});

test("this delete_sheet.js with 0.182.0's session_actions.js: a chain delete's toast says the stopped tasks once", async () => {
  const { createSessionActions } = await mixedPage("session_actions.js");
  const chainPlan = { chained: true, session_id: B, position: 2, size: 2, cut_off: false,
                      link: { digest: "dl", previous_id: A, moved: 0, notes: 0, delegates: { delete: [], leave: [] }, tasks: TASKS },
                      chain: { digest: "dc", links: 2, deletes: 0, delegates: { delete: [], leave: [] }, tasks: TASKS } };
  const stopped = { tasks_stopped: TASKS.running, tasks_not_stopped: [] };
  const h = harness(createSessionActions, {
    list: [{ id: A, archived: true }, { id: B, continues: A }],
    api: { deletePlan: async () => chainPlan, deleteChain: async () => ({ deleted: [A, B], left: [], ...stopped }) },
  });
  h.actions.confirmDelete(B, { anchor: { card: true } });
  await tick();
  h.sheet.hosts[0].flow.act("chain");
  await tick();
  assert.deepEqual(h.alerts, []);
  assert.equal(h.toasts.length, 1);
  // The old caller adds the stopped tasks after the toast's own words, as 0.182.0 did.
  assert.equal(h.toasts[0].text, "Deleted the chain: 2 sessions. · stopped 1 background task");
  assert.deepEqual(h.world.sessions, []);
});

test("this delete_sheet.js with 0.182.0's session_actions.js: a plan that can't be read is the sheet's Can't, nothing thrown", async () => {
  const { createSessionActions } = await mixedPage("session_actions.js");
  const h = harness(createSessionActions, {
    list: [{ id: A, archived: true }, { id: B, continues: A }],
    api: { deletePlan: async () => { throw failure(500, null, "disk full"); } },
  });
  h.actions.confirmDelete(B, { anchor: { card: true } });
  await tick();
  assert.match(h.sheet.hosts[0].shown.at(-1), /Can't delete 3f2a91c0 now/);
  assert.deepEqual(h.world.sessions.map((s) => s.id), [A, B]);
});
