import test from "node:test";
import assert from "node:assert/strict";
import { createSessionStore, MAX_PASSES, ORDER } from "../../../lib/samagotchi/web/public/session_store.js";

// A log that records instead of printing.
function quietLog() {
  const errors = [];
  return { errors, error: (...args) => errors.push(args.map(String).join(" ")) };
}

// Every redraw registered, each pushing its name onto +ran+ when it runs.
function recording(store) {
  const ran = [];
  for (const name of ORDER) store.on(name, () => ran.push(name));
  return ran;
}

const FIELDS = {
  owner: { redraws: ["composer", "infoBar"] },
  ctxPct: { redraws: ["infoBar"] },
  llmContext: { redraws: ["llmContextChip", "workingSetStrategy", "infoBar"] },
  streamSeq: { redraws: [] },
};

test("the getters: nothing open, the initial fields, an empty list", () => {
  const initial = { owner: null, ctxPct: null };
  const store = createSessionStore({ initial });
  assert.equal(store.selected, null);
  assert.equal(store.current, initial);
  assert.deepEqual(store.sessions, []);
});

test("update writes the selection, the fields in place and a new list", () => {
  const store = createSessionStore({ initial: { owner: null, ctxPct: null } });
  const held = store.current;
  const list = [{ id: "a" }];
  store.update({ selected: "a", current: { owner: "worker", ctxPct: 12 }, sessions: list });
  assert.equal(store.selected, "a");
  assert.equal(store.current, held, "the same object, written in place");
  assert.deepEqual(held, { owner: "worker", ctxPct: 12 });
  assert.equal(store.sessions, list);
  store.update({ selected: null });
  assert.equal(store.selected, null);
});

test("a part left out of the patch is left alone", () => {
  const store = createSessionStore({ initial: { owner: "tui" } });
  store.update({ selected: "a", sessions: [{ id: "a" }] });
  store.update({ current: { owner: "worker" } });
  assert.equal(store.selected, "a");
  assert.deepEqual(store.sessions, [{ id: "a" }]);
});

test("replaceCurrent always makes a new object: a held one keeps the old fields", () => {
  const fresh = { owner: null };
  const store = createSessionStore({ initial: { owner: "worker" } });
  const old = store.current;
  store.replaceCurrent(fresh);
  assert.notEqual(store.current, old);
  assert.notEqual(store.current, fresh);
  assert.deepEqual(store.current, { owner: null });
  // A stale async writer holding the old object writes there alone.
  old.owner = "tui";
  assert.equal(store.current.owner, null);
});

test("a write redraws once, at once, in ORDER", () => {
  const store = createSessionStore({ initial: { owner: null, llmContext: null }, fields: FIELDS });
  const ran = recording(store);
  store.update({ current: { owner: "worker", llmContext: { strategy: "forget" } } });
  assert.deepEqual(ran, ["llmContextChip", "workingSetStrategy", "composer", "infoBar"]);
});

test("an unchanged value, or a field that redraws nothing, runs no redraw", () => {
  const store = createSessionStore({ initial: { owner: "worker", streamSeq: null }, fields: FIELDS });
  const ran = recording(store);
  store.update({ current: { owner: "worker", streamSeq: 4 } });
  assert.deepEqual(ran, []);
  assert.equal(store.current.streamSeq, 4);
});

test("the list redraws the lists and the bar; the selection the active card, the composer and the bar", () => {
  const store = createSessionStore({ fields: FIELDS });
  const ran = recording(store);
  store.update({ sessions: [{ id: "a" }] });
  assert.deepEqual(ran.splice(0), ["lists", "infoBar"]);
  store.update({ selected: "a" });
  assert.deepEqual(ran.splice(0), ["paintActive", "composer", "infoBar"]);
  store.update({ sessions: store.sessions });
  assert.deepEqual(ran, [], "the same list is no change");
});

test("subscribers of one redraw run in the order they registered", () => {
  const store = createSessionStore({ initial: { ctxPct: null }, fields: FIELDS });
  const ran = [];
  store.on("infoBar", () => ran.push("first"));
  store.on("lists", () => ran.push("lists"));
  store.on("infoBar", () => ran.push("second"));
  store.update({ current: { ctxPct: 3 }, sessions: [] });
  assert.deepEqual(ran, ["lists", "first", "second"]);
});

test("on() refuses a name not in ORDER", () => {
  const store = createSessionStore();
  assert.throws(() => store.on("nope", () => {}), /no redraw called nope/);
});

test("touch runs that redraw", () => {
  const store = createSessionStore();
  const ran = recording(store);
  store.touch("infoBar");
  assert.deepEqual(ran, ["infoBar"]);
});

test("nested batches redraw once, at the end of the outermost", () => {
  const store = createSessionStore({ initial: { owner: null, ctxPct: null }, fields: FIELDS });
  const ran = recording(store);
  const result = store.batch(() => {
    store.update({ current: { ctxPct: 1 } });
    store.batch(() => {
      store.update({ current: { owner: "worker" } });
      store.touch("lists");
    });
    assert.deepEqual(ran, [], "nothing redraws inside");
    store.update({ current: { ctxPct: 2 } });
    return "done";
  });
  assert.equal(result, "done");
  assert.deepEqual(ran, ["lists", "composer", "infoBar"]);
});

test("a throw inside a batch: what was written redraws, the error is rethrown, later writes redraw again", () => {
  const store = createSessionStore({ initial: { ctxPct: null }, fields: FIELDS });
  const ran = recording(store);
  assert.throws(() => store.batch(() => {
    store.update({ current: { ctxPct: 5 } });
    throw new Error("render failed");
  }), /render failed/);
  assert.deepEqual(ran.splice(0), ["infoBar"]);
  assert.equal(store.current.ctxPct, 5);
  // Not stuck in a batch: the next write redraws at once.
  store.update({ current: { ctxPct: 6 } });
  assert.deepEqual(ran, ["infoBar"]);
});

test("a throw inside a batch whose redraw throws too: the batch's error, the redraw's logged", () => {
  const log = quietLog();
  const store = createSessionStore({ initial: { ctxPct: null }, fields: FIELDS, log });
  store.on("infoBar", () => { throw new Error("bar broke"); });
  assert.throws(() => store.batch(() => {
    store.update({ current: { ctxPct: 5 } });
    throw new Error("render failed");
  }), /render failed/);
  assert.equal(log.errors.length, 1);
  assert.match(log.errors[0], /bar broke/);
});

test("batch refuses an async function: logged, the redraws run at once", async () => {
  const log = quietLog();
  const store = createSessionStore({ initial: { ctxPct: null }, fields: FIELDS, log });
  const ran = recording(store);
  const result = store.batch(async () => {
    store.update({ current: { ctxPct: 1 } });
    await null;
  });
  assert.equal(log.errors.length, 1);
  assert.match(log.errors[0], /synchronous/);
  assert.deepEqual(ran, ["infoBar"], "the synchronous part's redraw, not held");
  await result;
  // Not left inside a batch.
  store.update({ current: { ctxPct: 2 } });
  assert.deepEqual(ran, ["infoBar", "infoBar"]);
});

test("a write during a flush only enqueues: the next pass runs it, after the rest of this pass", () => {
  const store = createSessionStore({ initial: { owner: null, ctxPct: null }, fields: FIELDS });
  const ran = [];
  store.on("lists", () => {
    ran.push("lists");
    // A nested flush would run the bar here, before composer.
    store.update({ current: { ctxPct: 9 } });
    store.batch(() => store.touch("paintActive"));
  });
  store.on("paintActive", () => ran.push("paintActive"));
  store.on("composer", () => ran.push("composer"));
  store.on("infoBar", () => ran.push("infoBar"));
  store.update({ sessions: [], current: { owner: "worker" } });
  assert.deepEqual(ran, ["lists", "composer", "infoBar", "paintActive", "infoBar"]);
});

test("redraws that keep writing stop at the pass cap, named in the log", () => {
  const log = quietLog();
  const store = createSessionStore({ initial: { ctxPct: 0 }, fields: FIELDS, log });
  let runs = 0;
  store.on("infoBar", () => {
    runs += 1;
    store.update({ current: { ctxPct: runs } });
  });
  store.touch("infoBar");
  assert.equal(runs, MAX_PASSES);
  assert.equal(log.errors.length, 1);
  assert.match(log.errors[0], /infoBar/);
  // The flush ended: a later write redraws again.
  store.touch("infoBar");
  assert.equal(runs, MAX_PASSES * 2);
});

test("a redraw that throws doesn't stop the others; its error comes after", () => {
  const store = createSessionStore({ initial: { owner: null }, fields: FIELDS });
  const ran = [];
  store.on("composer", () => { throw new Error("composer broke"); });
  store.on("infoBar", () => ran.push("infoBar"));
  assert.throws(() => store.update({ current: { owner: "tui" } }), /composer broke/);
  assert.deepEqual(ran, ["infoBar"]);
  assert.equal(store.current.owner, "tui");
});

test("setStatus turnEnd while a turn runs: the newer turn's running stays, no redraw (D3)", () => {
  const store = createSessionStore({ initial: { status: "running" }, fields: { status: { redraws: ["infoBar"] } } });
  const ran = recording(store);
  assert.equal(store.setStatus("idle", "turnEnd", { running: true }), false);
  assert.equal(store.current.status, "running");
  assert.deepEqual(ran, []);
  store.setStatus("idle", "turnEnd", { running: false });
  assert.equal(store.current.status, "idle");
  assert.deepEqual(ran, ["infoBar"]);
});
