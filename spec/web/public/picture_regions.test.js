import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { html } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { CARD_ROOM, COARSE_CARD_ROOM, createRegionLayer, regionName, regionTitle } from "../../../lib/samagotchi/web/public/picture_regions.js";

const SIZE = { width: 1000, height: 500 };
const BR = { kind: "node", id: "BR", label: "Bridge", box: [0.4, 0.4, 0.1, 0.1] };
const EN = { kind: "node", id: "EN", label: "Engine", box: [0.7, 0.4, 0.1, 0.1] };
const UP = { kind: "node", id: "M", label: "Model", box: [0.7, 0.1, 0.1, 0.1] };
const G = { kind: "group", id: "worker", label: "Worker process", box: [0.35, 0.05, 0.6, 0.6] };
const EDGE = { kind: "edge", id: "", label: "events", from: "BR", to: "EN", points: [[0.5, 0.45], [0.7, 0.45]], box: [0.58, 0.41, 0.04, 0.03] };
const DOWN = { kind: "edge", id: "", label: "down", from: "", to: "", points: [[0.45, 0.5], [0.45, 0.9]] };
const PICTURE = { url: "data:x", width: 1000, height: 500, regions: [G, BR, EN, UP, EDGE] };

function setup(picture = PICTURE, opts = {}) {
  const box = document.createElement("div");
  box.className = "pv-pic";
  const viewer = document.createElement("div");
  viewer.tabIndex = -1;
  viewer.append(box);
  document.body.append(viewer);
  const selections = [];
  const told = [];
  const layer = createRegionLayer({ onSelect: (r) => selections.push(r), ...opts });
  layer.mount(box);
  viewer.append(layer.card, layer.live);
  layer.bind({ selected: (r, how) => told.push([r, how]), home: () => viewer.focus() });
  layer.show(picture);
  const q = (sel) => viewer.querySelector(sel);
  const qa = (sel) => [...viewer.querySelectorAll(sel)];
  return { layer, box, viewer, selections, told, q, qa, buttons: () => qa(".pv-node") };
}
const key = (el, k) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
  el.dispatchEvent(e);
  return e;
};

test.afterEach(() => { document.body.innerHTML = ""; });

test("draws a button per region, named for a screen reader, in a group that counts them", () => {
  const { q, buttons } = setup();
  assert.equal(q(".pv-nodes").getAttribute("role"), "group");
  assert.equal(q(".pv-nodes").getAttribute("aria-label"), "Diagram: 3 nodes, 1 arrow, 1 group");
  assert.deepEqual(buttons().map((b) => b.getAttribute("aria-label")), ["group Worker process, worker", "node Bridge, BR", "node Engine, EN", "node Model, M", "arrow Bridge to Engine, events"]);
  assert.match(buttons()[1].getAttribute("style"), /left:40%;top:40%;width:10%;height:10%/);
  assert.ok(buttons().every((b) => b.type === "button"));
});

test("each button carries its own inline reset: placed, see-through, no pointer, whatever the stylesheet", () => {
  const edge = { ...EDGE };
  delete edge.box;
  const { buttons } = setup({ ...PICTURE, regions: [BR, edge] });
  for (const b of buttons()) {
    const style = b.getAttribute("style");
    for (const rule of ["position:absolute", "pointer-events:none", "background:none", "border:0", "padding:0", "margin:0"]) assert.ok(style.includes(rule), `${rule} in ${style}`);
  }
});

test("an edge's button without a label box is a 24 px square at its middle point", () => {
  const edge = { ...EDGE, box: undefined };
  delete edge.box;
  const { buttons } = setup({ ...PICTURE, regions: [BR, EN, edge] });
  assert.match(buttons()[2].getAttribute("style"), /left:calc\(70% - 12px\);top:calc\(45% - 12px\);width:24px;height:24px/);
});

test("no regions: nothing drawn, no room, every hook inert", () => {
  const { layer, box, q } = setup({ url: "data:x", width: 10, height: 10 });
  assert.equal(box.querySelector(".pv-marks").children.length, 0);
  assert.equal(layer.room(), 0);
  assert.equal(layer.tap({ x: 0.45, y: 0.45 }, SIZE, "mouse"), null);
  assert.equal(layer.hover({ x: 0.45, y: 0.45 }, SIZE), false);
  assert.equal(layer.key({ target: document.body, key: "ArrowLeft" }), false);
  assert.equal(q(".pv-sel").hidden, true);
});

test("never bound (an older cached picture_viewer.js): nothing drawn, no room; bound, both", () => {
  const box = document.createElement("div");
  document.body.append(box);
  const layer = createRegionLayer();
  layer.mount(box);
  layer.show(PICTURE);
  assert.equal(box.querySelectorAll(".pv-node").length, 0);
  assert.equal(box.querySelector(".pv-marks").children.length, 0);
  assert.equal(layer.room(), 0);
  layer.bind({});
  assert.equal(box.querySelectorAll(".pv-node").length, 5);
  assert.equal(layer.room(), CARD_ROOM);
});

test("with regions the card's room is kept", () => {
  assert.equal(setup().layer.room(), CARD_ROOM);
});

test("a coarse pointer's room, its media query made once, read on each paint", () => {
  const asked = [];
  const mql = { matches: true };
  const win = { matchMedia: (q) => { asked.push(q); return mql; } };
  const { layer } = setup(PICTURE, { win });
  for (let i = 0; i < 5; i++) assert.equal(layer.room(), COARSE_CARD_ROOM);
  mql.matches = false;
  assert.equal(layer.room(), CARD_ROOM);
  assert.deepEqual(asked, ["(pointer:coarse)"]);
});

test("a tap selects what is under it and shows the card; a tap on empty space clears", () => {
  const { layer, q, qa, selections, told } = setup();
  assert.equal(layer.tap({ x: 0.45, y: 0.45 }, SIZE, "mouse"), BR);
  assert.equal(layer.selected(), BR);
  assert.equal(q(".pv-sel").hidden, false);
  assert.equal(q(".pv-sel-kind").textContent, "node");
  assert.equal(q(".pv-sel-label").textContent, "Bridge");
  assert.equal(q(".pv-sel-id").textContent, "BR");
  assert.equal(qa(".pv-mark.pv-on").length, 1);
  assert.deepEqual(told.at(-1), [BR, "tap"]);
  assert.equal(layer.tap({ x: 0.01, y: 0.99 }, SIZE, "mouse"), null);
  assert.equal(layer.selected(), null);
  assert.equal(q(".pv-sel").hidden, true);
  assert.equal(qa(".pv-mark.pv-on").length, 0);
  assert.deepEqual(selections, [BR, null]);
});

test("a finger's tap takes the nearest node within 18 px; a mouse's needs 3", () => {
  const { layer } = setup();
  const near = { x: 0.4 - 0.012, y: 0.45 }; // 12 px left of Bridge, in the group
  assert.equal(layer.tap(near, SIZE, "touch"), BR);
  assert.equal(layer.tap(near, SIZE, "mouse"), G);
});

test("an arrow's card names its ends by their labels, with its own label", () => {
  const { layer, q } = setup();
  layer.tap({ x: 0.6, y: 0.45 }, SIZE, "mouse");
  assert.equal(layer.selected(), EDGE);
  assert.equal(q(".pv-sel-kind").textContent, "arrow");
  assert.equal(q(".pv-sel-label").textContent, "Bridge → Engine · events");
  assert.equal(q(".pv-sel-id"), null);
  assert.equal(regionTitle({ ...EDGE, from: "X", to: "Y" }, [BR]), "X → Y · events");
  assert.equal(regionName({ ...EDGE, from: "", to: "" }, []), "arrow events");
});

test("two regions with one id mark together, behind one button", () => {
  const top = { kind: "node", id: "A", label: "Alice", box: [0.1, 0.05, 0.1, 0.1] };
  const bottom = { ...top, box: [0.1, 0.85, 0.1, 0.1] };
  const { layer, qa, buttons } = setup({ ...PICTURE, regions: [top, bottom] });
  assert.equal(buttons().length, 1);
  layer.tap({ x: 0.15, y: 0.9 }, SIZE, "mouse");
  assert.equal(qa(".pv-mark.pv-on").length, 2);
});

test("only the hovered and the selected edges have a line", () => {
  const { layer, qa } = setup({ ...PICTURE, regions: [...PICTURE.regions, DOWN] });
  assert.equal(qa("polyline").length, 0);
  assert.equal(layer.hover({ x: 0.6, y: 0.45 }, SIZE), true);
  assert.deepEqual(qa("polyline").map((p) => p.getAttribute("class")), ["pv-hover"]);
  assert.equal(qa("polyline")[0].getAttribute("points"), "0.5,0.45 0.7,0.45");
  assert.equal(qa("svg.pv-lines")[0].getAttribute("style"), "position:absolute;inset:0;width:100%;height:100%;overflow:visible;pointer-events:none");
  assert.equal(qa("polyline")[0].getAttribute("fill"), "none");
  layer.tap({ x: 0.6, y: 0.45 }, SIZE, "mouse");
  assert.deepEqual(qa("polyline").map((p) => p.getAttribute("class")), ["pv-on"], "the selected one has no hover line");
  layer.hover({ x: 0.45, y: 0.7 }, SIZE);
  assert.deepEqual(qa("polyline").map((p) => p.getAttribute("class")), ["pv-hover", "pv-on"]);
  assert.equal(layer.hover(null, SIZE), false);
  assert.equal(qa("polyline").length, 1);
});

test("one Tab stop, which follows the selection", () => {
  const { layer, buttons } = setup();
  const stops = () => buttons().filter((b) => b.tabIndex === 0).map((b) => b.getAttribute("aria-label"));
  assert.deepEqual(stops(), ["group Worker process, worker"]);
  layer.tap({ x: 0.75, y: 0.45 }, SIZE, "mouse");
  assert.deepEqual(stops(), ["node Engine, EN"]);
  assert.equal(buttons()[2].getAttribute("aria-pressed"), "true");
  assert.equal(buttons()[1].getAttribute("aria-pressed"), "false");
});

test("the arrows move the focus to the nearest node that way, and the stop with it", () => {
  const { layer, buttons } = setup();
  const bridge = buttons()[1];
  bridge.focus();
  const e = { target: bridge, key: "ArrowRight", preventDefault() {} };
  assert.equal(layer.key(e), true);
  assert.equal(document.activeElement.getAttribute("aria-label"), "arrow Bridge to Engine, events");
  layer.key({ target: document.activeElement, key: "ArrowRight" });
  assert.equal(document.activeElement.getAttribute("aria-label"), "node Engine, EN");
  layer.key({ target: document.activeElement, key: "ArrowUp" });
  assert.equal(document.activeElement.getAttribute("aria-label"), "node Model, M");
  assert.deepEqual(buttons().filter((b) => b.tabIndex === 0).map((b) => b.getAttribute("aria-label")), ["node Model, M"]);
  assert.equal(layer.key({ target: document.activeElement, key: "Enter" }), false, "Enter is the button's own click");
});

test("a click on a button (Enter, Space, an assistive activation) selects it, at once", () => {
  const { layer, buttons, told } = setup();
  buttons()[2].click();
  assert.equal(layer.selected(), EN);
  assert.deepEqual(told.at(-1), [EN, "key"]);
  buttons()[2].click();
  assert.equal(told.length, 1, "selecting the selected one is a no-op");
});

test("the live line says what a pointer selected", () => {
  const { layer, q } = setup();
  assert.equal(q(".pv-live").getAttribute("aria-live"), "polite");
  layer.tap({ x: 0.45, y: 0.45 }, SIZE, "touch");
  assert.equal(q(".pv-live").textContent, "node Bridge, BR selected");
  layer.select(null);
  assert.equal(q(".pv-live").textContent, "");
});

test("✕ clears; the focus inside the card goes to the cleared region's button, else to the viewer", () => {
  const { layer, q, buttons, viewer } = setup();
  layer.tap({ x: 0.45, y: 0.45 }, SIZE, "mouse");
  q(".pv-sel-x").focus();
  q(".pv-sel-x").click();
  assert.equal(layer.selected(), null);
  assert.ok(document.activeElement === buttons()[1]);
  const stray = { ...DOWN }; // not one of the picture's: no button
  layer.select(stray);
  assert.equal(layer.selected(), stray);
  q(".pv-sel-x").focus();
  layer.select(null);
  assert.ok(document.activeElement === viewer);
});

test("a label of markup is its characters: no element is made; an id like a selector is text", () => {
  const evil = { kind: "node", id: "\"]", label: "<img src=x onerror=alert(1)>", box: [0.1, 0.1, 0.2, 0.2] };
  const { layer, box, q, buttons } = setup({ ...PICTURE, regions: [evil] });
  layer.tap({ x: 0.15, y: 0.15 }, SIZE, "mouse");
  assert.equal(q(".pv-sel-label").textContent, "<img src=x onerror=alert(1)>");
  assert.equal(q(".pv-sel-id").textContent, "\"]");
  assert.equal(buttons()[0].getAttribute("aria-label"), "node <img src=x onerror=alert(1)>, \"]");
  // In an attribute's value a "<" serializes as itself (the HTML spec): so no element, and the card's text escaped.
  assert.equal(box.querySelectorAll("img, [onerror]").length + q(".pv-sel").querySelectorAll("img").length, 0);
  assert.doesNotMatch(q(".pv-sel").innerHTML, /<img/);
  assert.equal(document.querySelectorAll("img").length, 0);
});

test("the card's actions row is the caller's, shown only when it has one", () => {
  const { layer, q } = setup(PICTURE, { actions: (r) => html`<button type="button" class="act">Annotate ${r.id}</button>` });
  layer.tap({ x: 0.45, y: 0.45 }, SIZE, "mouse");
  assert.equal(q(".pv-sel-acts .act").textContent, "Annotate BR");
  document.body.innerHTML = "";
  const plain = setup();
  plain.layer.tap({ x: 0.45, y: 0.45 }, SIZE, "mouse");
  assert.equal(plain.q(".pv-sel-acts"), null);
});

test("show and clear reset the selection", () => {
  const { layer, q } = setup();
  layer.tap({ x: 0.45, y: 0.45 }, SIZE, "mouse");
  layer.show(PICTURE);
  assert.equal(layer.selected(), null);
  assert.equal(q(".pv-sel").hidden, true);
  layer.clear();
  assert.equal(layer.room(), 0);
  assert.equal(q(".pv-nodes"), null);
});
