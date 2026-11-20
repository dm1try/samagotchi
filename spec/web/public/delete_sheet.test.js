// The delete sheet (delete_sheet.js): a chained session's choices from the
// server's delete plan (GET …/delete_plan, SessionChain::Delete::Preview),
// the refusals in place, the toasts and the flow. The mock-up's scenes are
// the spec (docs/internals/web-frontend.md, delete_sheet.js).
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createDeleteSheet, deleteChoices, deleteSheetTemplate, deleteToast, isChained, listAfterDelete, refusalModel,
         refusalTemplate, runDeleteFlow } from "../../../lib/samagotchi/web/public/delete_sheet.js";

const B = "3f2a91c0-0000-0000-0000-000000000003";
const A = "1a2b3c4d-0000-0000-0000-000000000002";
const C = "9d0e1f2a-0000-0000-0000-000000000009";
const session = { id: B, title: "Nightly triage", continues: A };

const newest = () => ({
  chained: true, session_id: B, position: 3, size: 3, cut_off: false,
  link: { previous_id: A, moved: 2, notes: 1, unarchived: 1, deletes: 1, left_running: 1, earlier: 2, next_id: null,
          later: 0, refusal: null },
  chain: { links: 3, deletes: 4, left_running: 1, refusal: null },
});

test("a session is chained when it continues one or a listed one continues it", () => {
  assert.equal(isChained({ id: B, continues: A }, []), true);
  assert.equal(isChained({ id: A }, [{ id: B, continues: A }]), true);
  assert.equal(isChained({ id: C }, [{ id: B, continues: A }]), false);
  assert.equal(isChained(null), false);
});

test("scene 1: the newest link undoes the continue, naming what comes back and what goes", () => {
  const model = deleteChoices(session, newest());

  assert.equal(model.title, 'Delete 3f2a91c0 — "Nightly triage"?');
  assert.equal(model.sub, "It is link 3 of 3 of its chain. This can't be undone.");
  const [mine, chain] = model.choices;
  assert.equal(mine.label, "Delete this link");
  assert.deepEqual(mine.lines, [
    "Undoes the continue: 1a2b3c4d comes back to the lists (not started), with what this link took over from it — its 2 delegates and 1 unread note.",
    "What this link did itself goes: its turns and its 1 stopped delegate. Its 1 running delegate keeps running on its own.",
  ]);
  assert.equal(chain.label, "Delete the whole chain · 3 sessions");
  assert.deepEqual(chain.lines, ["All 3 links and their 4 stopped delegates. 1 running delegate keeps running on its own."]);
  assert.equal(model.foot, "Running workers are stopped first.");
  assert.equal(model.banner, null);
});

test("scene 2: a middle link splits the chain, nothing undone", () => {
  const plan = newest();
  plan.position = 2;
  plan.link = { previous_id: null, moved: 0, notes: 0, unarchived: 0, deletes: 2, left_running: 0, earlier: 1, next_id: B,
                later: 1, refusal: null };
  const model = deleteChoices({ id: A, title: "Nightly triage" }, plan);

  assert.deepEqual(model.choices[0].lines, [
    "The chain splits: 1 earlier link stays archived, and 3f2a91c0 goes on as a chain of its own.",
    "Nothing is undone. Its 2 stopped delegates go with it.",
  ]);
});

test("scene 3A: a schedule on the chain says so once and turns both choices off", () => {
  const plan = newest();
  const message = "an enabled schedule runs on this chain; cancel it with chi schedule cancel abc123";
  plan.link.refusal = { reason: "scheduled", message: "this session is the target of an enabled schedule", schedule_id: "abc123" };
  plan.chain.refusal = { reason: "chain_scheduled", message, schedule_id: "abc123" };
  const model = deleteChoices(session, plan);

  assert.equal(model.banner, "An enabled schedule runs on this chain; cancel it with chi schedule cancel abc123.");
  assert.deepEqual(model.choices.map((c) => [c.disabled, c.why]),
                   [[true, "Not while a schedule runs the chain."], [true, "Not while a schedule runs the chain."]]);
  const markup = markupOf(deleteSheetTemplate(model));
  assert.match(markup, /class="ds-banner"/);
  assert.match(markup, />Close</);
});

test("scene 3B: a moved delegate that can't go back offers the stop only when the page can stop it", () => {
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

test("tasks_running: the sheet names the tasks the delete takes and offers to stop them", () => {
  const tasks = { running: [{ session_id: B, id: "20261120-3f9a2c1d", command: "npm run dev" },
                            { session_id: C, id: "20261120-0badf00d", command: "rspec" }],
                  unverified: [{ session_id: B, id: "20261001-11112222", command: "rails s" }], unreadable: [] };
  const model = refusalModel({ reason: "tasks_running", tasks, sessionId: B }, A);

  assert.equal(model.title, "Background tasks still running");
  assert.equal(model.text, "3 background tasks this delete takes are still running: " +
                           "npm run dev · 9d0e1f2a: rspec · task 11112222 (may still be running). Nothing was deleted.");
  assert.equal(model.stop.label, "Stop them and delete");
  assert.equal(model.stop.line, "They are stopped (TERM, then KILL after 3 s), then the session goes.");
  assert.match(markupOf(refusalTemplate(model)), /data-act="del:stop"/);
});

test("scene 5: a gap before the link: the whole-chain choice says the earlier links are kept", () => {
  const plan = newest();
  plan.cut_off = true;
  plan.chain = { links: 2, deletes: 1, left_running: 0, refusal: null };
  const chain = deleteChoices(session, plan).choices[1];

  assert.equal(chain.label, "Delete the whole chain · 2 sessions");
  assert.deepEqual(chain.lines, ["These 2 links, and their 1 stopped delegate."]);
  assert.equal(chain.warn, "Earlier links, cut off by a deleted link, are kept (archived).");
});

test("the More panel's sheet has ‹ More; a card's has ×", () => {
  const model = deleteChoices(session, newest());
  assert.match(markupOf(deleteSheetTemplate(model, { back: true })), /data-act="del:back"[^>]*>‹ More</);
  assert.doesNotMatch(markupOf(deleteSheetTemplate(model)), /‹ More/);
});

test("scene 7: the toasts after each choice", () => {
  assert.deepEqual(deleteToast("this", { unarchived: [A], moved_back: [C, "x"] }, newest(), B),
                   { text: "Deleted 3f2a91c0. 1a2b3c4d is back, with 2 delegates and 1 note.", back: A });
  // The sheet's count, subtrees included, over the direct ids the 200 lists.
  const deep = newest();
  deep.link.moved = 3;
  assert.equal(deleteToast("this", { unarchived: [A], moved_back: [C, "x"] }, deep, B).text,
               "Deleted 3f2a91c0. 1a2b3c4d is back, with 3 delegates and 1 note.");
  assert.deepEqual(deleteToast("this", { unarchived: [], moved_back: [] }, newest(), B), { text: "Deleted 3f2a91c0.", back: null });
  const chain = { deleted: ["d1", "d2", "d3", "d4", "l1", "l2", "l3"], left: [], left_running: ["r1"] };
  assert.equal(deleteToast("chain", chain, newest(), B).text,
               "Deleted the chain: 3 sessions and 4 delegates. 1 running delegate was left on its own.");
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

test("the flow: reads the plan, runs 'this link', closes and reports", async () => {
  const host = fakeHost();
  const done = [];
  const calls = [];
  const plan = { ...newest(), link: { ...newest().link, digest: "link-digest" } };
  const api = {
    deletePlan: async () => plan,
    deleteSession: async (id, opts) => { calls.push([id, opts]); return { unarchived: [A], deleted: [B] }; },
  };
  const flow = runDeleteFlow({ id: B, session, host, api, done: (...args) => done.push(args), plain: () => {}, failed: () => {} });
  await tick();
  assert.match(host.shown.at(-1), /Delete this link/);

  flow.act("this");
  await tick();
  assert.equal(host.closed, 1);
  assert.equal(done[0][0], "this");
  assert.deepEqual(calls, [[B, { expect: "link-digest" }]]);
});

test("the flow sends the chain choice's digest", async () => {
  const host = fakeHost();
  const calls = [];
  const plan = { ...newest(), chain: { ...newest().chain, digest: "chain-digest" } };
  const flow = runDeleteFlow({
    id: B, session, host,
    api: { deletePlan: async () => plan, deleteChain: async (id, opts) => { calls.push([id, opts]); return { deleted: [B] }; } },
    done: () => {}, plain: () => {}, failed: () => {},
  });
  await tick();
  flow.act("chain");
  await tick();

  assert.deepEqual(calls, [[B, { expect: "chain-digest" }]]);
});

test("the flow: a plan that says no chain falls back to today's confirm", async () => {
  const host = fakeHost();
  let plain = 0;
  runDeleteFlow({ id: B, session, host, api: { deletePlan: async () => ({ chained: false }) }, done: () => {}, plain: () => { plain += 1; }, failed: () => {} });
  await tick();
  assert.deepEqual([plain, host.closed], [1, 1]);
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
  const flow = runDeleteFlow({ id: B, session, host, api, done: () => calls.push("done"), plain: () => {}, failed: () => {} });
  await tick();
  flow.act("this");
  await tick(); await tick();
  // Whether it can be stopped is the 409's own word: no second plan read.
  assert.match(host.shown.at(-1), /Can't give 9d0e1f2a back/);
  assert.match(host.shown.at(-1), /data-act="del:stop"/);
  assert.equal(plans, 1);

  flow.act("stop");
  // A second tap while the stop runs does nothing (one stop loop).
  flow.act("stop");
  await tick();
  assert.match(host.shown.at(-1), /still running; try again in a moment/);
  assert.deepEqual(calls, ["delete", `stop ${C}`]);

  released = true;
  flow.act("stop");
  await tick(); await tick();
  assert.deepEqual(calls, ["delete", `stop ${C}`, `stop ${C}`, "delete", "done"]);
});

test("the flow: tasks_running's Stop them and delete sends the same choice and digest again, stopping the tasks", async () => {
  const host = fakeHost();
  const tasks = { running: [{ session_id: B, id: "20261120-3f9a2c1d", command: "npm run dev" }], unverified: [], unreadable: [] };
  const running = Object.assign(new Error("background tasks it started are still running: npm run dev"),
                                { code: "tasks_running", body: { error: "tasks_running", op: "delete", tasks } });
  const calls = [];
  const done = [];
  const plan = { ...newest(), chain: { ...newest().chain, digest: "chain-digest" } };
  const api = {
    deletePlan: async () => plan,
    deleteChain: async (id, opts) => { calls.push([id, opts]); if (calls.length === 1) throw running; return { deleted: [B] }; },
    stopSession: async () => { calls.push("stop"); return { released: true }; },
  };
  const flow = runDeleteFlow({ id: B, session, host, api, done: (...args) => done.push(args), plain: () => {}, failed: () => {} });
  await tick();
  flow.act("chain");
  await tick(); await tick();
  assert.match(host.shown.at(-1), /Background tasks still running/);
  assert.match(host.shown.at(-1), /1 background task this delete takes is still running: npm run dev\. Nothing was deleted\./);

  flow.act("stop");
  await tick(); await tick();
  assert.deepEqual(calls, [[B, { expect: "chain-digest" }], [B, { expect: "chain-digest", stopTasks: true }]]);
  assert.equal(done[0][0], "chain");
});

test("the flow: plan_changed re-reads and redraws the changed plan before another confirmation", async () => {
  const host = fakeHost();
  const original = { ...newest(), link: { ...newest().link, digest: "old-link" } };
  const refreshed = {
    ...newest(),
    link: { ...newest().link, digest: "new-link", deletes: 2 },
    chain: { ...newest().chain, digest: "new-chain" },
  };
  const changed = Object.assign(new Error("plan changed"), { code: "plan_changed" });
  const calls = [];
  let reads = 0;
  const api = {
    deletePlan: async () => (++reads === 1 ? original : refreshed),
    deleteSession: async (id, opts) => {
      calls.push([id, opts]);
      if (calls.length === 1) throw changed;
      return { deleted: [B] };
    },
  };
  const flow = runDeleteFlow({ id: B, session, host, api, done: () => {}, plain: () => {}, failed: () => assert.fail() });
  await tick();
  flow.act("this");
  await tick();
  await tick();

  assert.equal(reads, 2);
  assert.match(host.shown.at(-1), /What this deletes changed; check again/);
  assert.match(host.shown.at(-1), /2 stopped delegates/);

  flow.act("this");
  await tick();
  assert.deepEqual(calls, [[B, { expect: "old-link" }], [B, { expect: "new-link" }]]);
});

test("the flow redraws a single-session confirmation if the refreshed plan is no longer chained", async () => {
  const host = fakeHost();
  const original = { ...newest(), link: { ...newest().link, digest: "old-link" } };
  const changed = Object.assign(new Error("plan changed"), { code: "plan_changed" });
  const calls = [];
  let reads = 0;
  const flow = runDeleteFlow({
    id: B, session, host,
    api: {
      deletePlan: async () => (++reads === 1 ? original : { chained: false, session_id: B }),
      deleteSession: async (id, opts) => {
        calls.push([id, opts]);
        if (calls.length === 1) throw changed;
        return { deleted: [B] };
      },
    },
    done: () => {}, plain: () => assert.fail(), failed: () => assert.fail(),
  });
  await tick();
  flow.act("this");
  await tick();
  await tick();

  assert.equal(reads, 2);
  assert.match(host.shown.at(-1), /What this deletes changed; check again/);
  assert.match(host.shown.at(-1), /no longer in a chain/);

  flow.act("this");
  await tick();
  assert.deepEqual(calls, [[B, { expect: "old-link" }], [B, { expect: undefined }]]);
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
    host.wire(runDeleteFlow({ id, session: { id, title: id === A ? "first" : "second" }, host, api,
                              done: () => {}, plain: () => {}, failed: () => {} }));
  };

  start(A, cardA);
  start(B, cardB);
  await tick();
  assert.equal(sheet.openFor(), B);
  assert.match(sheet.pop.textContent, /"second"/);

  answerA();
  await tick();
  assert.match(sheet.pop.textContent, /"second"/);
  assert.doesNotMatch(sheet.pop.textContent, /"first"/);

  sheet.pop.querySelector('[data-act="del:chain"]').click();
  await tick();
  assert.deepEqual(calls, [["chain", B]]);
  sheet.close();
  cardA.remove();
  cardB.remove();
});
