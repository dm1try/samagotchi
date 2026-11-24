// The page's list of pages (pages_model.js): one read shared while it is
// out, an older answer dropped, a failed read keeping the last list, and the
// subscribers told after each answer. And All sessions' group reading
// through it (pages_group.js with a model).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createPagesModel } from "../../../lib/samagotchi/web/public/pages_model.js";
import { createPagesGroup } from "../../../lib/samagotchi/web/public/pages_group.js";

const page = (name) => ({ name, title: name, state: "never_ran", ran_at: null, failed_at: null });

// An api whose answers the test hands out, in any order.
function deferredApi() {
  const asks = [];
  const api = (path) => new Promise((resolve, reject) => asks.push({ path, resolve, reject }));
  return { api, asks };
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("load: one read while one is out; the state and the subscribers follow its answer", async () => {
  const { api, asks } = deferredApi();
  const model = createPagesModel({ api });
  const seen = [];
  model.subscribe((state) => seen.push(state.pages.map((p) => p.name)));
  assert.deepEqual(model.state(), { pages: [], loaded: false, failed: false });
  const a = model.load();
  const b = model.load();
  assert.equal(a, b, "the same read");
  await tick();
  assert.equal(asks.length, 1);
  asks[0].resolve({ pages: [page("usage")] });
  await a;
  assert.deepEqual(model.state(), { pages: [page("usage")], loaded: true, failed: false });
  assert.deepEqual(seen, [["usage"]]);
  model.load();
  await tick();
  assert.equal(asks.length, 2, "a load after the answer reads again");
});

test("reload asks again while a read is out, and the older answer is dropped", async () => {
  const { api, asks } = deferredApi();
  const model = createPagesModel({ api });
  const seen = [];
  model.subscribe((state) => seen.push(state.pages.map((p) => p.name)));
  const first = model.load();
  const second = model.reload();
  await tick();
  assert.equal(asks.length, 2);
  asks[1].resolve({ pages: [page("new")] });
  await second;
  asks[0].resolve({ pages: [page("old")] });
  await first;
  assert.deepEqual(model.state().pages.map((p) => p.name), ["new"]);
  assert.deepEqual(seen, [["new"]]);
});

test("a failed read keeps the last list and loaded; failed says so until a read succeeds", async () => {
  const { api, asks } = deferredApi();
  const model = createPagesModel({ api });
  const done = model.load();
  await tick();
  asks[0].resolve({ pages: [page("usage")] });
  await done;
  const failing = model.reload();
  await tick();
  asks[1].reject(new Error("offline"));
  await failing;
  assert.deepEqual(model.state(), { pages: [page("usage")], loaded: true, failed: true });
  const back = model.reload();
  await tick();
  asks[2].resolve({ pages: [] });
  await back;
  assert.deepEqual(model.state(), { pages: [], loaded: true, failed: false });
});

test("an api that throws at once: the read fails, and the next load reads again", async () => {
  let calls = 0;
  const model = createPagesModel({ api: () => { calls += 1; throw new Error("no"); } });
  await model.load();
  assert.equal(model.state().failed, true);
  await model.load();
  assert.equal(calls, 2);
});

test("an unsubscribed subscriber is told nothing", async () => {
  const model = createPagesModel({ api: async () => ({ pages: [page("a")] }) });
  const seen = [];
  const off = model.subscribe(() => seen.push(1));
  off();
  await model.load();
  assert.deepEqual(seen, []);
});

test("All sessions' group reads through a model: its load is the model's, a failed read empties it", async () => {
  document.body.innerHTML = '<input id="filter"><div id="pagesGroup" hidden></div>';
  const root = document.querySelector("#pagesGroup");
  let answer = { pages: [page("usage")] };
  const calls = [];
  const model = createPagesModel({ api: async (path) => { calls.push(path); if (answer instanceof Error) throw answer; return answer; } });
  const g = createPagesGroup({ root, filterEl: document.querySelector("#filter"), api: () => assert.fail("its own read"), open: () => {}, model });
  await g.load();
  assert.deepEqual(calls, ["/api/pages"]);
  assert.equal(root.hidden, false);
  answer = new Error("offline");
  await model.reload();
  assert.equal(root.hidden, true);
});
