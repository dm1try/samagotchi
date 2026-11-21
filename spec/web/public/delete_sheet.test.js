// The delete sheet (delete_sheet.js, its words removal_sheet_model.js): the
// sheet for every session from the server's delete plan (GET …/delete_plan,
// SessionChain::Delete::Preview), a chained session's two choices, archive's
// ask, the refusals in place, the toasts and the flow. The mock-up's 14
// cases are the spec (docs/internals/web-frontend.md, The delete sheet):
// https://claude.ai/artifact/1A3TL2kkz8a2Pv8obi4jsj
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createDeleteSheet, deleteChoices, deleteSheetTemplate, isChained, listAfterDelete, refusalModel,
         refusalTemplate, runDeleteFlow } from "../../../lib/samagotchi/web/public/delete_sheet.js";
import { archiveSheetModel, buttonWords, deleteToast, sheetGroups,
         stopTasksOptions } from "../../../lib/samagotchi/web/public/removal_sheet_model.js";

const B = "3f2a91c0-0000-0000-0000-000000000003";
const A = "1a2b3c4d-0000-0000-0000-000000000002";
const C = "9d0e1f2a-0000-0000-0000-000000000009";
const session = { id: B, title: "Nightly triage", continues: A };

// The mock-up's session and its delegates.
const S = "ab12cd34-0000-0000-0000-000000000001";
const D1 = "9d0e1f2a-0000-0000-0000-000000000011";
const D2 = "77aa0b1c-0000-0000-0000-000000000012";
const R1 = "5c1b22e0-0000-0000-0000-000000000013";
const LIST = [{ id: S, title: "fix the flaky spec" }, { id: D1, title: "run the specs", parent_id: S },
              { id: D2, auto_title: "lint pass", parent_id: S, archived: true }, { id: R1, title: "watch the deploy", parent_id: S }];
const TASK1 = { session_id: S, id: "20261120-3f9a2c1d", command: "npm run dev" };
const TASK2 = { session_id: S, id: "20261120-0badf00d", command: "rspec" };
const NO_TASKS = { running: [], unverified: [], unreadable: [] };

// A session in no chain's plan (the route's JSON): +link+ fields over the
// plain case.
const plain = (link = {}) => ({
  chained: false, session_id: S,
  link: { digest: "d0", previous_id: null, moved: 0, notes: 0, unarchived: 0, deletes: 0, left_running: 0, earlier: 0,
          next_id: null, later: 0, delegates: { delete: [], leave: [] }, tasks: NO_TASKS, worker: null, refusal: null, ...link },
});
const model = (link) => deleteChoices(LIST[0], plain(link), LIST);
// A row's text as the sheet draws it, its parts joined.
const text = (group) => group.lines.map((line) => line.map((p) => (typeof p === "string" ? p : p.b ?? p.dim)).join("")).join("\n");
const rows = (m) => Object.fromEntries(m.groups.map((g) => [g.label, text(g)]));

test("case 1: nothing else to it: one row, Delete, the foot", () => {
  const m = model();
  assert.equal(m.title, 'Delete ab12cd34 — "fix the flaky spec"?');
  assert.deepEqual(rows(m), { Goes: "Its history, notes and images." });
  assert.equal(m.button, "Delete");
  assert.equal(m.foot, "This can't be undone.");
  const markup = markupOf(deleteSheetTemplate(m));
  assert.match(markup, /class="ds-go danger" data-act="del:this">Delete</);
  assert.match(markup, />Cancel</);
});

test("case 2: stopped delegates go with it, named from the page's list; the button counts the sessions", () => {
  const m = model({ deletes: 2, delegates: { delete: [D1, D2], leave: [] } });
  assert.deepEqual(rows(m), { Goes: 'Its history, notes and images.\n2 stopped delegates: 9d0e1f2a "run the specs" · 77aa0b1c "lint pass"' });
  assert.equal(m.button, "Delete · 3 sessions");
  // Three names at most, then +N more; an id the list doesn't hold is its short id.
  const many = sheetGroups({ delegates: { delete: [D1, D2, R1, "0f0f0f0f-x", "1e1e1e1e-y"], leave: [] } }, { sessions: LIST });
  assert.match(text(many[0]), /5 stopped delegates: .* · 5c1b22e0 "watch the deploy" \+2 more$/);
  assert.match(text(sheetGroups({ delegates: { delete: ["0f0f0f0f-x"], leave: [] } })[0]), /1 stopped delegate: 0f0f0f0f$/);
});

test("case 3: background tasks: Stopped first names them (a delegate's with its id), the button stops them", () => {
  const tasks = { running: [TASK1, { session_id: D1, id: "20261120-12345678", command: "rspec" }], unverified: [], unreadable: [] };
  const m = model({ tasks, worker: "idle" });
  assert.equal(rows(m)["Stopped first"], "Its worker (idle).\n2 background tasks: npm run dev · 9d0e1f2a: rspec");
  assert.equal(m.button, "Stop them and delete");
  assert.equal(buttonWords({ tasks: { running: [TASK1] } }), "Stop it and delete");
  assert.match(markupOf(deleteSheetTemplate(m)), /Its worker <span class="dim">\(idle\)<\/span>\./);
});

test("case 4: a running delegate stays, named, not counted in the button; its stopped delegates stay with it", () => {
  const m = model({ left_running: 1, delegates: { delete: [], leave: [{ id: R1, running: true }] } });
  assert.equal(rows(m).Stays, '1 running delegate: 5c1b22e0 "watch the deploy" keeps running on its own, without a parent.');
  assert.equal(m.button, "Delete");
  const under = model({ left_running: 2, delegates: { delete: [], leave: [{ id: R1, running: true }, { id: D1, running: false }] } });
  assert.match(rows(under).Stays, /^1 running delegate, with its 1 delegate: 5c1b22e0 "watch the deploy" keeps running/);
});

test("case 5: a running turn: the row says it, the button names it; an idle worker is only a row", () => {
  const m = model({ worker: "turn" });
  assert.equal(rows(m)["Stopped first"], "Its running turn: it ends as stopped, its worker goes.");
  assert.equal(m.button, "Stop the turn and delete");
  assert.equal(model({ worker: "idle" }).button, "Delete");
  assert.equal(buttonWords({ worker: "turn", tasks: { running: [TASK1] } }), "Stop the turn and tasks and delete");
});

test("case 6: everything at once: all three rows, Stop them and delete · 3 sessions", () => {
  const m = model({ deletes: 2, left_running: 1, worker: "idle",
                    delegates: { delete: [D1, D2], leave: [{ id: R1, running: true }] },
                    tasks: { running: [TASK1, TASK2], unverified: [], unreadable: [] } });
  assert.deepEqual(m.groups.map((g) => g.key), ["goes", "stop", "stays"]);
  assert.equal(m.button, "Stop them and delete · 3 sessions");
});

test("case 7: a task chi can't verify is under Stays; the button is Delete, and the tap still sends the stop (H2)", () => {
  const tasks = { running: [], unverified: [{ session_id: S, id: "20261001-3f9a2c1d", command: "rails s" }], unreadable: [] };
  const m = model({ tasks });
  assert.equal(rows(m).Stays, "1 task chi can't verify: task 3f9a2c1d (may still be running). chi leaves it as it is.");
  assert.equal(m.button, "Delete");
  assert.equal(m.stops, false);
  assert.deepEqual(stopTasksOptions(tasks), { stopTasks: true, tasks: [] });
  assert.deepEqual(stopTasksOptions(NO_TASKS), {});
  assert.deepEqual(stopTasksOptions({ ...tasks, running: [TASK1] }), { stopTasks: true, tasks: [TASK1.id] });
});

// A chained session's plan (the mock-up's case 8 and the chain scenes).
const newest = () => ({
  chained: true, session_id: B, position: 3, size: 3, cut_off: false,
  link: { previous_id: A, moved: 2, notes: 1, unarchived: 1, deletes: 1, left_running: 1, earlier: 2, next_id: null,
          later: 0, refusal: null },
  chain: { links: 3, deletes: 4, left_running: 1, refusal: null },
});

test("case 8: a chain link keeps its two choices, each with its own rows and button words", () => {
  const plan = newest();
  plan.link.tasks = { running: [TASK1, TASK2], unverified: [], unreadable: [] };
  plan.link.delegates = { delete: [D1], leave: [{ id: R1, running: true }] };
  plan.chain.tasks = { running: [TASK1, TASK2, { session_id: A, id: "x-1", command: "tail -f log" }], unverified: [], unreadable: [] };
  plan.chain.worker = { idle: 1, turn: 0 };
  const m = deleteChoices(session, plan);
  const [mine, chain] = m.choices;
  assert.equal(m.sub, "It is link 3 of 3 of its chain. This can't be undone.");
  assert.equal(mine.label, "Stop 2 tasks and delete this link");
  assert.deepEqual(mine.lines, [
    { cls: "", text: "Undoes the continue: 1a2b3c4d comes back to the lists (not started), with its 2 delegates and 1 unread note." },
    { cls: "dim", text: "Goes: its turns and its 1 stopped delegate." },
    { cls: "stop", text: "Stopped first: ab12cd34: npm run dev · ab12cd34: rspec" },
    { cls: "stays", text: "Stays: 1 running delegate, on its own." },
  ]);
  assert.equal(chain.label, "Stop 3 tasks and delete the whole chain · 3 sessions");
  assert.deepEqual(chain.lines.map((l) => l.text), ["Goes: all 3 links and their 4 stopped delegates.",
                                                    "Stopped first: ab12cd34: npm run dev · ab12cd34: rspec · 1a2b3c4d: tail -f log",
                                                    "Stays: 1 running delegate, on its own."]);
  assert.equal(m.foot, "Running workers are stopped first.");
  // No task, no turn: today's words.
  const bare = deleteChoices(session, newest()).choices;
  assert.deepEqual(bare.map((c) => c.label), ["Delete this link", "Delete the whole chain · 3 sessions"]);
});

test("a chain's middle link splits the chain, nothing undone", () => {
  const plan = newest();
  plan.position = 2;
  plan.link = { previous_id: null, moved: 0, notes: 0, unarchived: 0, deletes: 2, left_running: 0, earlier: 1, next_id: B,
                later: 1, refusal: null };
  assert.deepEqual(deleteChoices({ id: A, title: "Nightly triage" }, plan).choices[0].lines.map((l) => l.text), [
    "The chain splits: 1 earlier link stays archived, and 3f2a91c0 goes on as a chain of its own. Nothing is undone.",
    "Goes: its turns and its 2 stopped delegates.",
  ]);
});

test("a gap before the link: the whole-chain choice says the earlier links are kept", () => {
  const plan = newest();
  plan.cut_off = true;
  plan.chain = { links: 2, deletes: 1, left_running: 0, refusal: null };
  const chain = deleteChoices(session, plan).choices[1];
  assert.equal(chain.label, "Delete the whole chain · 2 sessions");
  assert.deepEqual(chain.lines.map((l) => l.text), ["Goes: these 2 links and their 1 stopped delegate."]);
  assert.equal(chain.warn, "Earlier links, cut off by a deleted link, are kept (archived).");
});

test("a schedule on the chain says so once and turns both choices off", () => {
  const plan = newest();
  const message = "an enabled schedule runs on this chain; cancel it with chi schedule cancel abc123";
  plan.link.refusal = { reason: "scheduled", message: "this session is the target of an enabled schedule", schedule_id: "abc123" };
  plan.chain.refusal = { reason: "chain_scheduled", message, schedule_id: "abc123" };
  const m = deleteChoices(session, plan);
  assert.equal(m.banner, "An enabled schedule runs on this chain; cancel it with chi schedule cancel abc123.");
  assert.deepEqual(m.choices.map((c) => [c.disabled, c.why]),
                   [[true, "Not while a schedule runs the chain."], [true, "Not while a schedule runs the chain."]]);
  const markup = markupOf(deleteSheetTemplate(m));
  assert.match(markup, /class="ds-banner"/);
  assert.match(markup, />Close</);
});

test("case 9: a refusal the plan carries is Can't delete … now, with only Close", () => {
  const m = model({ refusal: { reason: "scheduled", message: "this session is the target of an enabled schedule; cancel it with chi schedule cancel nightly-deps" } });
  assert.deepEqual(m, { title: "Can't delete ab12cd34 now", close: true,
                        sub: "This session is the target of an enabled schedule; cancel it with chi schedule cancel nightly-deps." });
  const markup = markupOf(deleteSheetTemplate(m));
  assert.doesNotMatch(markup, /data-act="del:this"/);
  assert.match(markup, /data-act="del:cancel">Close</);
  // A terminal's one-turn run: the plan says it (no alert).
  assert.equal(model({ refusal: { reason: "owned_by_tui", message: "session ab12 is busy in a one-turn chi; let it finish first" } }).sub,
               "Session ab12 is busy in a one-turn chi; let it finish first.");
});

test("a moved delegate that can't go back offers the stop only when the page can stop it", () => {
  const older = refusalModel({ reason: "delegate_unmovable", ids: [C], stoppable: true }, A);
  assert.equal(older.title, "Can't give 9d0e1f2a back");
  assert.match(older.text, /took over from 1a2b3c4d, runs on an older chi worker that can't be moved back\. Nothing was deleted\./);
  assert.equal(older.stop.label, "Stop its worker, then delete");
  assert.match(markupOf(refusalTemplate(older)), /data-act="del:stop"/);
  const oneTurn = refusalModel({ reason: "delegate_unmovable", ids: [C], stoppable: false }, A);
  assert.match(oneTurn.text, /let it finish first/);
  assert.equal(oneTurn.stop, null);
  assert.deepEqual(refusalModel({ reason: "continuing", message: "a continue of 3f2a91c0 is under way; try again in a moment" }),
                   { title: "Not deleted", text: "a continue of 3f2a91c0 is under way; try again in a moment", stop: null });
});

const tasksRunning = (op, tasks, extra = {}) => Object.assign(new Error("background tasks it started are still running"),
  { code: "tasks_running", body: { error: "tasks_running", op, session_id: S, tasks, ...extra } });

test("case 12: archive's ask from its 409: Hidden (it and its delegates), Stopped first, Stop them and archive", () => {
  const tasks = { running: [TASK1, { session_id: D1, id: "x-2", command: "rspec" }], unverified: [], unreadable: [] };
  const m = archiveSheetModel(LIST[0], tasksRunning("archive", tasks, { sessions: 3 }), LIST);
  assert.equal(m.title, 'Archive ab12cd34 — "fix the flaky spec"?');
  assert.deepEqual(rows(m), { Hidden: "It and its 2 delegates leave the lists and are kept for good.",
                              "Stopped first": "2 background tasks: npm run dev · 9d0e1f2a: rspec" });
  assert.equal(m.button, "Stop them and archive");
  assert.equal(m.foot, "Undo brings the sessions back. Stopped tasks stay stopped.");
  assert.match(markupOf(deleteSheetTemplate(m, { act: "archive" })), /class="ds-go warn" data-act="del:archive">Stop them and archive</);
  assert.equal(text(archiveSheetModel({ id: S }, tasksRunning("archive", tasks)).groups[0]), "It leaves the lists and is kept for good.");
});

test("case 13: any other archive refusal is Can't archive … now with Close", () => {
  const busy = Object.assign(new Error("its delegate 5c1b22e0 is running a turn; wait for it or stop it first"),
                             { code: "busy", body: { reason: "busy_child", busy_id: R1 } });
  assert.deepEqual(archiveSheetModel(LIST[0], busy), { title: "Can't archive ab12cd34 now", close: true,
                                                       sub: "Its delegate 5c1b22e0 is running a turn; wait for it or stop it first." });
});

test("case 14: the toast after a delete: what went, what was stopped, what stays; a delegate left running is offered", () => {
  const result = { deleted: [S, D1, D2], left_running: [R1], tasks_stopped: [TASK1, TASK2], tasks_not_stopped: [] };
  assert.deepEqual(deleteToast("this", result, plain(), S),
                   { text: "Deleted ab12cd34 and 2 delegates · stopped 2 background tasks · 5c1b22e0 keeps running", back: R1 });
  assert.deepEqual(deleteToast("this", { deleted: [S] }, plain(), S), { text: "Deleted ab12cd34", back: null });
  assert.equal(deleteToast("this", { deleted: [S], left_running: [R1, D1] }, plain(), S).text, "Deleted ab12cd34 · 2 delegates keep running");
  // A newest link's undo: the link that came back is the one offered.
  assert.deepEqual(deleteToast("this", { unarchived: [A], moved_back: [C, "x"] }, newest(), B),
                   { text: "Deleted 3f2a91c0. 1a2b3c4d is back, with 2 delegates and 1 note.", back: A });
  const deep = newest();
  deep.link.moved = 3;
  assert.equal(deleteToast("this", { unarchived: [A], moved_back: [C, "x"] }, deep, B).text,
               "Deleted 3f2a91c0. 1a2b3c4d is back, with 3 delegates and 1 note.");
  const chain = { deleted: ["d1", "d2", "d3", "d4", "l1", "l2", "l3"], left: [], left_running: ["r1"] };
  assert.equal(deleteToast("chain", chain, newest(), B).text, "Deleted the chain: 3 sessions and 4 delegates · r1 keeps running.");
});

test("the toast counts only the delegates still running: a stopped one under a running delegate stays with it, unsaid", () => {
  // left_running is the running delegates with their subtrees; the plan marks the stopped ones.
  const under = plain({ delegates: { delete: [], leave: [{ id: R1, running: true }, { id: D1, running: false }] } });
  assert.deepEqual(deleteToast("this", { deleted: [S], left_running: [R1, D1] }, under, S),
                   { text: "Deleted ab12cd34 · 5c1b22e0 keeps running", back: R1 });
  const chainPlan = newest();
  chainPlan.chain.delegates = { delete: [], leave: [{ id: R1, running: true }, { id: D1, running: false }] };
  assert.deepEqual(deleteToast("chain", { deleted: ["l1", "l2", "l3"], left: [], left_running: [R1, D1] }, chainPlan, B),
                   { text: "Deleted the chain: 3 sessions · 5c1b22e0 keeps running.", back: R1 });
});

test("isChained is kept for an older cached page: it still says which sessions are in a chain", () => {
  assert.equal(isChained({ id: B, continues: A }, []), true);
  assert.equal(isChained({ id: A }, [{ id: B, continues: A }]), true);
  assert.equal(isChained({ id: C }, [{ id: B, continues: A }]), false);
});

test("the More panel's sheet has ‹ More; a card's has ×", () => {
  for (const m of [deleteChoices(session, newest()), model()]) {
    assert.match(markupOf(deleteSheetTemplate(m, { back: true })), /data-act="del:back"[^>]*>‹ More</);
    assert.doesNotMatch(markupOf(deleteSheetTemplate(m)), /‹ More/);
  }
});

test("after a delete the list drops what went and flips what came back", () => {
  const list = [{ id: A, archived: true }, { id: B }, { id: C, parent_id: B }];
  assert.deepEqual(listAfterDelete(list, { deleted: [C, B], unarchived: [A] }), [{ id: A, archived: false }]);
});

// A host that keeps what it was given.
function fakeHost() {
  const host = { back: false, shown: [], closed: 0, flow: null };
  host.show = (tpl) => host.shown.push(markupOf(tpl));
  host.close = () => { host.closed += 1; };
  host.wire = (flow) => { host.flow = flow; };
  return host;
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const flowOf = (opts) => runDeleteFlow({ done: () => {}, failed: () => {}, sessions: LIST, ...opts });

test("the flow: a session in no chain reads its plan, shows its sheet; the tap sends expect alone with no task", async () => {
  const host = fakeHost();
  const calls = [];
  const done = [];
  const flow = flowOf({ id: S, session: LIST[0], host, done: (...args) => done.push(args),
                        api: { deletePlan: async () => plain({ delegates: { delete: [D1], leave: [] } }),
                               deleteSession: async (id, opts) => { calls.push([id, opts]); return { deleted: [S, D1] }; } } });
  assert.match(host.shown[0], /Reading what this delete would do/);
  await tick();
  assert.match(host.shown.at(-1), /Delete · 2 sessions/);
  flow.act("this");
  assert.match(host.shown.at(-1), /data-act="del:this" disabled="">Deleting…</);
  await tick();
  assert.deepEqual(calls, [[S, { expect: "d0" }]]);
  assert.deepEqual([host.closed, done[0][0]], [1, "this"]);
});

test("the flow: with tasks the one tap sends expect and stopTasks with the named ids together, and says Stopping…", async () => {
  const host = fakeHost();
  const calls = [];
  const tasks = { running: [TASK1, TASK2], unverified: [{ session_id: S, id: "old-1" }], unreadable: [] };
  const flow = flowOf({ id: S, session: LIST[0], host,
                        api: { deletePlan: async () => plain({ tasks }), deleteSession: async (id, opts) => { calls.push([id, opts]); return {}; } } });
  await tick();
  flow.act("this");
  assert.match(host.shown.at(-1), />Stopping…</);
  await tick();
  assert.deepEqual(calls, [[S, { expect: "d0", stopTasks: true, tasks: [TASK1.id, TASK2.id] }]]);
});

test("the flow: only unverified records still send stopTasks (no ids), so the delete isn't refused in a loop (H2)", async () => {
  const host = fakeHost();
  const calls = [];
  const tasks = { running: [], unverified: [{ session_id: S, id: "old-1" }], unreadable: [] };
  const flow = flowOf({ id: S, session: LIST[0], host,
                        api: { deletePlan: async () => plain({ tasks }), deleteSession: async (id, opts) => { calls.push(opts); return {}; } } });
  await tick();
  flow.act("this");
  await tick();
  assert.deepEqual(calls, [{ expect: "d0", stopTasks: true, tasks: [] }]);
});

test("the flow sends the chain choice's digest and its own tasks", async () => {
  const host = fakeHost();
  const calls = [];
  const plan = newest();
  plan.chain.digest = "chain-digest";
  plan.chain.tasks = { running: [TASK2], unverified: [], unreadable: [] };
  const flow = flowOf({ id: B, session, host,
                        api: { deletePlan: async () => plan, deleteChain: async (id, opts) => { calls.push([id, opts]); return { deleted: [B] }; } } });
  await tick();
  flow.act("chain");
  await tick();
  assert.deepEqual(calls, [[B, { expect: "chain-digest", stopTasks: true, tasks: [TASK2.id] }]]);
});

for (const code of ["plan_changed", "tasks_running"]) {
  test(`case 10: ${code} re-reads the plan and shows it with the notice; nothing loops, the next tap sends the new plan`, async () => {
    const host = fakeHost();
    const refused = Object.assign(new Error("refused"), { code, body: { tasks: { running: [TASK1] } } });
    const calls = [];
    let reads = 0;
    const flow = flowOf({
      id: S, session: LIST[0], host,
      api: {
        deletePlan: async () => (++reads === 1 ? plain() : plain({ digest: "d1", tasks: { running: [TASK1], unverified: [], unreadable: [] } })),
        deleteSession: async (id, opts) => { calls.push(opts); if (calls.length === 1) throw refused; return {}; },
      },
      failed: () => assert.fail(),
    });
    await tick();
    flow.act("this");
    await tick(); await tick();
    assert.equal(reads, 2);
    assert.match(host.shown.at(-1), /What this deletes changed; check again\./);
    assert.match(host.shown.at(-1), />Stop it and delete</);
    flow.act("this");
    await tick();
    assert.deepEqual(calls, [{ expect: "d0" }, { expect: "d1", stopTasks: true, tasks: [TASK1.id] }]);
  });
}

test("the flow: a plan that can't be read is Can't delete in the sheet (no alert)", async () => {
  const host = fakeHost();
  const failed = [];
  flowOf({ id: S, session: LIST[0], host, failed: (e) => failed.push(e.message),
           api: { deletePlan: async () => { throw new Error("unknown session"); } } });
  await tick();
  assert.match(host.shown.at(-1), /Can't delete ab12cd34 now/);
  assert.match(host.shown.at(-1), /Unknown session\./);
  assert.deepEqual([failed, host.closed], [["unknown session"], 0]);
});

test("the flow: a refusal shows in place; Stop then delete retries only once the worker reads stopped", async () => {
  const host = fakeHost();
  const unmovable = Object.assign(new Error("can't go back"), { code: "delegate_unmovable", body: { ids: [C], stoppable: true } });
  const calls = [];
  let released = false;
  let plans = 0;
  const api = {
    deletePlan: async () => { plans += 1; return newest(); },
    deleteSession: async () => { calls.push("delete"); if (calls.length === 1) throw unmovable; return { deleted: [B] }; },
    stopSession: async (id) => { calls.push(`stop ${id}`); return { released }; },
  };
  const flow = flowOf({ id: B, session, host, api, done: () => calls.push("done") });
  await tick();
  flow.act("this");
  await tick(); await tick();
  assert.match(host.shown.at(-1), /Can't give 9d0e1f2a back/);
  assert.equal(plans, 1);
  flow.act("stop");
  flow.act("stop");
  await tick();
  assert.match(host.shown.at(-1), /still running; try again in a moment/);
  assert.deepEqual(calls, ["delete", `stop ${C}`]);
  released = true;
  flow.act("stop");
  await tick(); await tick();
  assert.deepEqual(calls, ["delete", `stop ${C}`, `stop ${C}`, "delete", "done"]);
});

test("the archive flow: its 409's sheet, the tap archives with the named ids; a new task re-shows it; another refusal is Can't", async () => {
  const host = fakeHost();
  const calls = [];
  const first = tasksRunning("archive", { running: [TASK1], unverified: [], unreadable: [] }, { sessions: 1 });
  const again = tasksRunning("archive", { running: [TASK1, TASK2], unverified: [], unreadable: [] }, { sessions: 1 });
  const answers = [again, { archived: [S] }];
  const done = [];
  const flow = flowOf({ id: S, session: LIST[0], host, archive: { refusal: first }, done: (...args) => done.push(args),
                        api: { archive: async (id, opts) => { calls.push(opts); const a = answers.shift(); if (a instanceof Error) throw a; return a; } } });
  assert.match(host.shown.at(-1), />Stop it and archive</);
  flow.act("archive");
  assert.match(host.shown.at(-1), />Stopping…</);
  await tick();
  assert.match(host.shown.at(-1), /What this archives changed; check again\./);
  assert.match(host.shown.at(-1), />Stop them and archive</);
  flow.act("archive");
  await tick();
  assert.deepEqual(calls, [{ stopTasks: true, tasks: [TASK1.id] }, { stopTasks: true, tasks: [TASK1.id, TASK2.id] }]);
  assert.deepEqual([host.closed, done[0][0], done[0][1]], [1, "archive", { archived: [S] }]);

  const other = fakeHost();
  const busy = Object.assign(new Error("a prompt is queued, which a resume would run; let it run first"), { code: "busy" });
  const f2 = flowOf({ id: S, session: LIST[0], host: other, archive: { refusal: first },
                      api: { archive: async () => { throw busy; } } });
  f2.act("archive");
  await tick();
  assert.match(other.shown.at(-1), /Can't archive ab12cd34 now/);
  assert.match(other.shown.at(-1), />Close</);
});

test("one shell, two cards: a ✕ on another card while the first plan is read takes the shell; the first answer draws and acts on nothing", async () => {
  const doc = document;
  const cardA = doc.createElement("button");
  cardA.dataset.del = A;
  const cardB = doc.createElement("button");
  cardB.dataset.del = B;
  doc.body.append(cardA, cardB);
  const sheet = createDeleteSheet({ doc, win: { innerWidth: 1024, innerHeight: 768 } });
  let answerA;
  const calls = [];
  const planFor = (id) => ({ ...newest(), session_id: id });
  const api = {
    deletePlan: (id) => (id === A ? new Promise((resolve) => { answerA = () => resolve(planFor(A)); }) : Promise.resolve(planFor(B))),
    deleteSession: async (id) => { calls.push(["this", id]); return { deleted: [id] }; },
    deleteChain: async (id) => { calls.push(["chain", id]); return { deleted: [id], left: [] }; },
  };
  const start = (id, card) => {
    const host = sheet.host(card, id);
    host.wire(flowOf({ id, session: { id, title: id === A ? "first" : "second" }, host, api }));
  };
  start(A, cardA);
  start(B, cardB);
  await tick();
  assert.equal(sheet.openFor(), B);
  assert.match(sheet.pop.textContent, /"second"/);
  answerA();
  await tick();
  assert.doesNotMatch(sheet.pop.textContent, /"first"/);
  sheet.pop.querySelector('[data-act="del:chain"]').click();
  await tick();
  assert.deepEqual(calls, [["chain", B]]);
  sheet.close();
  cardA.remove();
  cardB.remove();
});
