// A worker's recorded SSE events and chi web's actual show payload must draw
// the same history on today's page.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection", "CSS"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} };
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const { turnHistoryNodes } = await import("../../../lib/samagotchi/web/public/turn_block.js");
const { compareShapes, historyShape } = await import("../../../lib/samagotchi/web/public/history_shape.js");
const { livePage } = await import("./live_page.js");

const fixtureDir = new URL("../../shared/compat_wire/", import.meta.url);
const fixtureFiles = ["recording.json", "previous.json"].filter((name) => existsSync(new URL(name, fixtureDir)));

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

async function liveShape(events) {
  const { historyEl, turnDom, handlers } = livePage();
  const warnings = [];
  const warn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    for (const { type, data } of events) {
      assert.equal(data.type, type, `SSE event ${type} disagrees with its JSON type`);
      assert.equal(typeof handlers[type], "function", `no stream handler for ${type}`);
      await handlers[type]({ ...data });
    }
    turnDom.handOff({ immediate: true });
  } finally {
    console.warn = warn;
  }
  assert.deepEqual(warnings, [], "page logged an unknown-event or history warning");
  return historyShape(historyEl);
}

function reloadedShape(show) {
  document.body.innerHTML = '<div id="history"></div>';
  const historyEl = document.getElementById("history");
  const warnings = [];
  const warn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    historyEl.append(turnHistoryNodes(show.messages, {}, {
      thumbs: () => null,
      drawings: show.turn_drawings,
    }));
  } finally {
    console.warn = warn;
  }
  assert.deepEqual(warnings, [], "show replay logged an unknown-event or history warning");
  return historyShape(historyEl);
}

for (const filename of fixtureFiles) {
  const fixture = readJson(new URL(filename, fixtureDir));
  test(`${fixture.version}: recorded SSE and chi web show draw the same history`, async () => {
    const live = await liveShape(fixture.events);
    const reloaded = reloadedShape(fixture.show);
    const verdict = compareShapes(live, reloaded);
    assert.ok(verdict.same, `${fixture.version}\nlive: ${JSON.stringify(live, null, 1)}\nreloaded: ${JSON.stringify(reloaded, null, 1)}`);
    assert.ok(reloaded.length > 0, `${fixture.version}: chi web show drew no history`);
  });
}

test("the current recording fixture is present", () => {
  assert.ok(fixtureFiles.includes("recording.json"));
});
