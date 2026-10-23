import "./dom_shim.js";
import { Window } from "happy-dom";
import test from "node:test";
import assert from "node:assert/strict";
import { COLLAPSE_KEY, createWorkingSetRail, ringBucket } from "../../../lib/samagotchi/web/public/working_set_rail.js";
import { itemsOfTurn } from "../../../lib/samagotchi/web/public/working_set.js";

globalThis.matchMedia ??= () => ({ matches: false });
if (!("localStorage" in globalThis)) globalThis.localStorage = new Window().localStorage;

const read = (path) => ({ tool: "read", status: "ok", title: path, ref: { kind: "file", path } });
const items = (...paths) => itemsOfTurn({ gens: [{ tools: paths.map(read) }] }, 0);

function rail() {
  const stage = document.createElement("section");
  Object.defineProperty(stage, "clientWidth", { value: 1200 });
  const live = document.createElement("div");
  stage.append(live);
  document.body.append(stage);
  const opened = [];
  const r = createWorkingSetRail({ live, stage, onOpen: (el) => opened.push(el), onChange: () => {} });
  return { r, live, stage, opened, done: () => stage.remove() };
}

test("the rail: keyed lines (an unchanged one keeps its node), a fold at the budget, the aria label, the click opens", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const s = rail();
  assert.ok(s.live.lastElementChild === s.r.el);
  s.r.draw(items("lib/w/a.js"), { now: 0 });
  const first = s.r.el.querySelector(".ws-item");
  s.r.draw(items("lib/w/a.js", "lib/w/b.js"), { now: 10 });
  assert.ok(s.r.el.querySelector(".ws-item") === first, "the first line's node stays");
  // The second one is fresh (seen after the first draw), the first not.
  assert.deepEqual([...s.r.el.querySelectorAll(".ws-item")].map((n) => n.classList.contains("fresh")), [false, true]);
  s.r.draw(items("lib/w/a.js", "lib/w/b.js", "lib/w/c.js", "x/d.rb", "y/e.rb"), { now: 20 });
  t.mock.timers.tick(200);
  const lines = [...s.r.el.querySelectorAll(".ws-item")].sort((a, b) => Number(a.style.order) - Number(b.style.order)).map((n) => n.querySelector(".t").textContent);
  assert.deepEqual(lines, ["lib/w/", "d.rb", "e.rb"]);
  assert.equal(s.r.el.getAttribute("aria-label"), "Working set: lib/w 3 files, d.rb, e.rb. Open the list.");
  assert.equal(s.r.el.querySelector(".ws-count").textContent, "5");
  s.r.el.click();
  assert.ok(s.opened[0] === s.r.el);
  s.done();
});

test("the rail folds to its head line by its button (kept per browser); a click on the head line opens it again", () => {
  const s = rail();
  s.r.draw(items("a.rb"), { now: 0 });
  s.r.el.querySelector(".ws-fold").click();
  assert.equal(s.r.isCollapsed(), true);
  assert.equal(globalThis.localStorage.getItem(COLLAPSE_KEY), "1");
  assert.equal(s.r.el.getAttribute("aria-expanded"), "false");
  s.r.draw(items("a.rb"), { now: 0 });
  assert.equal(s.r.el.querySelector(".ws-name").textContent, "set");
  assert.equal(s.r.el.querySelector(".ws-tick").textContent, "a.rb");
  s.r.el.click();
  assert.equal(s.r.isCollapsed(), false);
  assert.equal(s.opened.length, 0);
  globalThis.localStorage.removeItem(COLLAPSE_KEY);
  s.done();
});

test("ringBucket: warn from 70 %, danger from 90 %", () => {
  assert.deepEqual([10, 70, 89, 90].map(ringBucket), ["", "warn", "warn", "danger"]);
});

test("the rail marks a line with a pending op (dashed, its title says it), in place; read-only", () => {
  const s = rail();
  s.r.draw(items("a.rb", "b.rb"), { now: 0 });
  const line = (name) => [...s.r.el.querySelectorAll(".ws-item")].find((n) => n.querySelector(".t").textContent === name);
  const a = line("a.rb");
  assert.equal(a.classList.contains("pending"), false);
  s.r.draw(items("a.rb", "b.rb"), { now: 0, pending: new Map([["file:a.rb", "drop"]]) });
  assert.ok(line("a.rb") === a, "the same node, patched");
  assert.ok(a.classList.contains("pending"));
  assert.match(a.title, /drops next turn$/);
  assert.equal(line("b.rb").classList.contains("pending"), false);
  assert.equal(s.r.el.querySelector("button.ws-act-b"), null);
  s.r.draw(items("a.rb", "b.rb"), { now: 0, pending: new Map() });
  assert.equal(a.classList.contains("pending"), false);
  s.done();
});
