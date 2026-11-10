// The session bar's fold (bar_fold.js): the rule over measured widths (pure),
// the signature that triggers it, and the watcher over a stand-in window
// (its widths, its ResizeObserver, its phone query), as chip_popover.test.js
// and strip_hidden.test.js stand in for theirs.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createBarFold, foldPlan, foldSignature, rowWidth } from "../../../lib/samagotchi/web/public/bar_fold.js";
import { BAR_ITEMS, barItemKeys, infoButtons } from "../../../lib/samagotchi/web/public/info_bar_model.js";
import { renderInfoBar } from "../../../lib/samagotchi/web/public/info_bar.js";

const ID = "0123456789abcdef";
const SPACING = { item: 8, group: 17, bar: 10, actions: 10 };
const item = (key) => BAR_ITEMS.find((i) => i.key === key);
const itemsOf = (...keys) => BAR_ITEMS.filter((i) => keys.includes(i.key));
const sorted = (set) => [...set].sort();

// Every key 50 px wide, ⚙ 80 (20 compact).
const widthsOf = (items) => Object.fromEntries(items.map((i) => [i.key, i.compact ? { full: 80, compact: 20 } : { full: 50 }]));
const plan = (keys, available, extra = {}) => {
  const items = itemsOf(...keys);
  return foldPlan({ items, widths: widthsOf(items), available, spacing: SPACING, ...extra });
};

const SOME = ["status", "ctx", "more", "id", "settings", "model", "toolkit", "notes", "dir", "archive", "delete"];

test("rowWidth: the groups' chips and gaps, a hairline's room between groups, the bar's gaps around #infoActions and ⋯", () => {
  // identity: status ctx (50+8+50) · setup: model (17+50) · bar gap · no buttons · bar gap · ⋯ 50.
  assert.equal(rowWidth(itemsOf("status", "ctx", "model", "more"), { widths: widthsOf(itemsOf("status", "ctx", "model", "more")), spacing: SPACING }),
               108 + 67 + 10 + 0 + 10 + 50);
  // The count adds its width only when something counted is folded.
  const widths = widthsOf(itemsOf("status", "more"));
  assert.equal(rowWidth(itemsOf("status", "more"), { widths, spacing: SPACING, countWidth: 12, counted: true }), 50 + 10 + 10 + 50 + 12);
});

test("foldPlan: everything fits, only the menu's own (archive, delete) are folded; no group empty but the relations", () => {
  const p = plan(SOME, 2000);
  assert.deepEqual(sorted(p.folded), ["archive", "delete"]);
  assert.deepEqual(sorted(p.compact), []);
  assert.deepEqual(p.emptyGroups, ["relations"]);
});

test("foldPlan: the lowest rank folds first, equal ranks fold together, an emptied group is reported", () => {
  const all = plan(SOME, 2000);
  const full = rowWidth(itemsOf(...SOME).filter((i) => !all.folded.has(i.key)), { widths: widthsOf(itemsOf(...SOME)), spacing: SPACING });
  // 1 px short: rank 1 (toolkit and dir) folds, both together, and the trail is empty.
  const p = plan(SOME, full - 1);
  assert.deepEqual(sorted(p.folded), ["archive", "delete", "dir", "toolkit"]);
  assert.deepEqual(p.emptyGroups, ["relations", "trail"]);
  // Shorter: notes (2), then the model (4).
  assert.deepEqual(sorted(plan(SOME, full - 130).folded), ["archive", "delete", "dir", "notes", "toolkit"]);
  assert.deepEqual(sorted(plan(SOME, full - 200).folded), ["archive", "delete", "dir", "model", "notes", "toolkit"]);
});

test("foldPlan: ⚙ goes compact before it folds; pinned items never fold, the row clips", () => {
  const keys = ["status", "ctx", "more", "settings"];
  // status 50 + 8 + ctx 50, 17 + ⚙ 80, 10 + 10, ⋯ 50 = 275.
  assert.deepEqual(sorted(plan(keys, 275).compact), []);
  const tight = plan(keys, 274);
  assert.deepEqual(sorted(tight.compact), ["settings"]);
  assert.deepEqual(sorted(tight.folded), []);
  const tighter = plan(keys, 214);
  assert.deepEqual(sorted(tighter.folded), ["settings"]);
  assert.deepEqual(sorted(tighter.compact), []);
  assert.deepEqual(tighter.emptyGroups, ["setup", "relations", "trail"]);
  const none = plan(keys, 10);
  assert.deepEqual(sorted(none.folded), ["settings"], "status, ctx and ⋯ stay: the row clips");
});

test("foldPlan: the phone keeps phone: menu items off the row, ⚙ compact from the start", () => {
  const p = plan([...SOME, "speed", "continue", "stop"], 2000, { profile: "phone" });
  assert.deepEqual(sorted(p.folded), ["archive", "continue", "delete", "dir", "id", "model", "notes", "stop", "toolkit"]);
  assert.deepEqual(sorted(p.compact), ["settings"]);
  // Narrower: speed (8) before ⚙ (10).
  const items = itemsOf("status", "ctx", "more", "speed", "settings");
  const widths = widthsOf(items);
  const width = rowWidth(items, { widths, compact: new Set(["settings"]), spacing: SPACING });
  assert.deepEqual(sorted(foldPlan({ items, widths, available: width - 1, profile: "phone", spacing: SPACING }).folded), ["speed"]);
});

test("foldPlan: ⋯'s count joins the row's width once something it counts is folded", () => {
  const keys = ["status", "ctx", "more", "dir"];
  const items = itemsOf(...keys);
  const widths = widthsOf(items);
  const width = rowWidth(items, { widths, spacing: SPACING });
  assert.deepEqual(sorted(foldPlan({ items, widths, available: width, spacing: SPACING, countWidth: 12 }).folded), []);
  // dir folds: the count shows; still within the room.
  assert.deepEqual(sorted(foldPlan({ items, widths, available: width - 1, spacing: SPACING, countWidth: 12 }).folded), ["dir"]);
});

const bare = {
  id: ID, status: "idle", model: { text: "qwen", title: "qwen", mismatch: false },
  chain: { prev: null, next: null, pruned: false }, parent: null, kids: null, settings: null,
  toolkit: { summary: null, defaultKit: null }, notes: { text: "notes: tone", title: "t" }, memories: [], workingSet: null, participants: null,
  dir: "/p", ctx: { text: "ctx 8%", tip: "t" }, speed: { text: "42 tok/s", tip: "s", empty: false }, clock: "1m 12s", worker: null,
};
const buttonsFor = () => infoButtons({ id: ID, state: { owner: "worker" }, chain: { next: null }, archived: false, continuing: false, streaming: true });

test("foldSignature: the live chips' ticks leave it; a status, a set count, a delegate waiting change it", () => {
  const sig = (bar) => foldSignature(bar, buttonsFor());
  const base = sig(bare);
  assert.equal(sig({ ...bare, clock: "1m 13s", ctx: { text: "ctx 9%", tip: "t" }, speed: { text: "50 tok/s", tip: "s" } }), base);
  assert.notEqual(sig({ ...bare, status: "running" }), base);
  assert.notEqual(sig({ ...bare, workingSet: { chip: { n: 9 } } }), sig({ ...bare, workingSet: { chip: { n: 10 } } }));
  assert.notEqual(sig({ ...bare, kids: { text: "⑂ 1", waitingText: "" } }), sig({ ...bare, kids: { text: "⑂ 1", waitingText: "1 waiting" } }));
  assert.equal(foldSignature(null, null), "");
});

// The page's #infoBar over a stand-in layout: each item's width from a table
// (a text longer than its first is wider), none while its key is folded;
// ⚙ is 20 px compact. The bar's width is set by the test.
function harness({ phone = false, width = 2000, bar = bare } = {}) {
  const barEl = document.createElement("div");
  barEl.id = "infoBar";
  barEl.innerHTML = '<div class="info" id="infoText"></div><div class="info-actions" id="infoActions"><button id="infoContinueBtn">continue →</button>' +
    '<button id="infoArchiveBtn">archive</button><button id="infoStopBtn">stop session</button><button id="infoDeleteBtn">delete</button></div>' +
    '<button id="infoMoreBtn">⋯<span class="more-count"></span></button>';
  document.body.append(barEl);
  let barWidth = width;
  Object.defineProperty(barEl, "clientWidth", { get: () => barWidth, configurable: true });
  const reads = [];
  const keyOf = (el) => BAR_ITEMS.find((i) => el.matches(i.selector))?.key;
  const attr = (name) => (barEl.getAttribute(name) || "").split(" ");
  const boxed = (el) => {
    const key = keyOf(el);
    return !(key && attr("data-folded").includes(key));
  };
  const widthOf = (el) => {
    const key = keyOf(el);
    reads.push(key);
    if (key === "more") return 30 + (el.querySelector(".more-count").textContent ? 12 : 0);
    if (key === "settings") return attr("data-compact").includes("settings") ? 20 : 80;
    return 10 + 5 * el.textContent.length;
  };
  const patch = (el) => {
    el.getClientRects = () => (boxed(el) ? [{}] : []);
    el.getBoundingClientRect = () => ({ width: boxed(el) ? widthOf(el) : 0 });
  };
  const resized = [];
  class ResizeObserver { constructor(fn) { resized.push(fn); } observe() {} }
  const listeners = [];
  const media = { matches: phone, addEventListener: (_t, fn) => listeners.push(fn) };
  const win = {
    matchMedia: (q) => (q.startsWith("(max-width") ? media : { matches: false, addEventListener() {} }),
    getComputedStyle: () => ({ paddingLeft: "0px", paddingRight: "0px", columnGap: "8px", display: "flex" }),
    ResizeObserver, devicePixelRatio: 1,
  };
  const changes = [];
  const fold = createBarFold({ barEl, keysFor: barItemKeys, win, doc: document, onChange: () => changes.push(1) });
  const draw = (b = bar) => {
    renderInfoBar(barEl.querySelector("#infoText"), b);
    barEl.querySelectorAll("*").forEach(patch);
    return fold.update({ bar: b, buttons: buttonsFor() });
  };
  return {
    barEl, fold, draw, reads, changes,
    resize: (w) => { barWidth = w; resized.forEach((fn) => fn()); },
    folded: () => attr("data-folded").filter(Boolean).sort(),
    done: () => barEl.remove(),
  };
}

test("the watcher: a wide bar folds only the menu's own; the attributes are on #infoBar", () => {
  const h = harness();
  const { folded } = h.draw();
  assert.deepEqual(sorted(folded), ["archive", "delete"]);
  assert.equal(h.barEl.getAttribute("data-folded"), "archive delete");
  assert.equal(h.barEl.getAttribute("data-empty-groups"), "relations");
  assert.equal(h.barEl.hasAttribute("data-compact"), false);
  h.done();
});

test("the watcher: a narrower bar refolds by itself, lowest rank first, and tells the page; wider again unfolds", () => {
  const h = harness();
  h.draw();
  h.resize(560);
  assert.ok(h.folded().includes("dir"));
  assert.ok(h.folded().includes("notes"));
  assert.ok(!h.folded().includes("id"));
  assert.equal(h.changes.length, 1);
  h.resize(2000);
  assert.deepEqual(h.folded(), ["archive", "delete"]);
  h.done();
});

test("the watcher: a tick within the live chips' budgets measures nothing; one past a budget refolds", () => {
  const h = harness();
  h.draw();
  h.resize(600);
  const before = h.folded();
  h.reads.length = 0;
  h.draw({ ...bare, clock: "1m 13s", ctx: { text: "ctx 9%", tip: "t" } });
  assert.deepEqual(h.reads.filter((k) => !["ctx", "speed", "time"].includes(k)), [], "only the live chips are read");
  assert.deepEqual(h.folded(), before);
  // The clock grows past its budget: the fold runs again, and the row gives way.
  h.draw({ ...bare, clock: "1326m 06s 000000" });
  assert.ok(h.folded().length > before.length);
  h.done();
});

test("the watcher: a text first seen while folded is measured by unfolding, before it is unfolded on the row", () => {
  const h = harness();
  h.draw();
  h.resize(480);
  assert.ok(h.folded().includes("notes"));
  // A longer note while folded: its width is read (with nothing folded) when the signature changes.
  h.reads.length = 0;
  h.draw({ ...bare, notes: { text: "notes: a much longer set of model notes", title: "t" } });
  assert.ok(h.reads.includes("notes"));
  h.done();
});

test("the watcher: the phone folds its menu items with ⚙ compact; a status change recomputes", () => {
  const h = harness({ phone: true, width: 380, bar: { ...bare, settings: { thinking: { level: "low", source: "session", own: "low" } } } });
  h.draw();
  assert.ok(h.folded().includes("id"));
  assert.ok(h.folded().includes("model"));
  assert.ok(!h.folded().includes("speed"));
  assert.equal(h.barEl.getAttribute("data-compact"), "settings");
  h.done();
});

// index.html's CSS hides a folded item by its key: every key that can fold has its selector there.
test("index.html: a data-folded rule for every key that can fold, a data-compact one for every compact form", () => {
  const html = readFileSync(new URL("../../../lib/samagotchi/web/public/index.html", import.meta.url), "utf8");
  for (const it of BAR_ITEMS.filter((i) => i.rank !== "pinned")) {
    assert.ok(html.includes(`#infoBar[data-folded~="${it.key}"]`), it.key);
  }
  for (const it of BAR_ITEMS.filter((i) => i.compact)) assert.ok(html.includes(`#infoBar[data-compact~="${it.key}"]`), it.key);
  for (const group of ["setup", "relations", "trail"]) assert.ok(html.includes(`#infoBar[data-empty-groups~="${group}"]`), group);
  assert.equal(item("more").rank, "pinned");
});
