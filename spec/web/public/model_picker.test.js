// The start page's model picker (model_picker.js), in happy-dom: the list
// it draws, the search, the keys and the pick. The rows and the matching
// are model_pick.js' (model_pick.test.js).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

const { createModelPicker } = await import("../../../lib/samagotchi/web/public/model_picker.js");
const { MODEL_KEY, RECENT_KEY } = await import("../../../lib/samagotchi/web/public/model_pick.js");

const PAYLOAD = {
  default: "fake",
  models: [
    { name: "fake", id: "fake" },
    { name: "other", id: "other", configured: true },
    { name: "box:alpha", host: "box", id: "alpha", configured: true },
    { name: "box:a<b>", host: "box", id: "a<b>" },
    { name: "down:zeta", host: "down", id: "zeta", unavailable: true },
  ],
};

function picker({ payload = PAYLOAD, stored = null, recent = [], remember } = {}) {
  localStorage.removeItem(MODEL_KEY);
  localStorage.setItem(RECENT_KEY, JSON.stringify(recent));
  document.body.innerHTML = `<div id="center"><div id="composer"><div id="modelPanel" hidden><input id="modelSearch"
    ><div id="modelList"></div></div><button id="modelPick"><span class="model-pick-name"></span></button></div></div>`;
  const $ = (sel) => document.querySelector(sel);
  const picks = [];
  const ctl = createModelPicker({ button: $("#modelPick"), panel: $("#modelPanel"), input: $("#modelSearch"),
                                  list: $("#modelList"), composer: $("#composer"), center: $("#center"),
                                  onPick: (name) => picks.push(name), ...(remember ? { remember } : {}) });
  ctl.setModels(payload, stored);
  const list = $("#modelList");
  const input = $("#modelSearch");
  const key = (k) => input.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
  const type = (text) => { input.value = text; input.dispatchEvent(new window.Event("input", { bubbles: true })); };
  // The list's markup, lit's marker comments dropped.
  const markup = () => list.innerHTML.replace(/<!--[^]*?-->/g, "");
  const rows = () => [...list.querySelectorAll(".model-option")].map((el) => el.textContent);
  const activeRow = () => list.querySelector(".model-option.active")?.textContent;
  return { ctl, list, input, button: $("#modelPick"), panel: $("#modelPanel"), key, type, markup, rows, activeRow, picks };
}

test("setModels preselects the stored name while it is offered, else the default; nothing offered keeps the button", () => {
  let p = picker({ stored: "box:alpha" });
  assert.equal(p.ctl.chosen(), "box:alpha");
  assert.equal(p.button.textContent, "box:alpha");
  assert.equal(p.ctl.chosenRow().host, "box");
  p = picker({ stored: "gone:x" });
  assert.equal(p.ctl.chosen(), "fake");
  assert.equal(p.ctl.setModels({ models: [] }, null), false);
  assert.equal(p.ctl.chosen(), "fake");
});

test("a chosen row whose host is down greys the button", () => {
  const p = picker({ stored: "down:zeta" });
  assert.equal(p.button.classList.contains("unavailable"), true);
});

test("opening lists Recent, then the default host's rows and each host's, at the chosen row", () => {
  const p = picker({ stored: "other", recent: ["box:alpha"] });
  p.button.click();
  assert.equal(p.ctl.isOpen(), true);
  assert.equal(p.panel.hidden, false);
  assert.equal(p.button.getAttribute("aria-expanded"), "true");
  assert.deepEqual([...p.list.querySelectorAll(".model-group")].map((el) => el.textContent),
    ["Recent", "default default host", "box", "down host down"]);
  assert.deepEqual(p.rows(), ["box · alphaconfig", "otherconfig", "fakedefault", "alphaconfig", "a<b>", "zetahost down"]);
  assert.equal(p.activeRow(), "otherconfig");
  assert.equal(p.input.getAttribute("aria-activedescendant"), "model-option-1");
  assert.match(p.markup(), /<div class="model-group" role="presentation">default <span>default host<\/span><\/div>/);
  const row = (i) => p.list.querySelector(`#model-option-${i}`);
  const attrs = (el) => Object.fromEntries([...el.attributes].map((at) => [at.name, at.value]));
  assert.deepEqual(attrs(row(0)), { class: "model-option", role: "option", id: "model-option-0", "aria-selected": "false",
                                    "data-index": "0", title: "served by config (hosts.box.models)" });
  assert.equal(row(0).innerHTML.replace(/<!--[^]*?-->/g, ""), '<span class="model-id"><span class="model-host">box</span>' +
    '<span class="model-dot"> · </span>alpha</span><span class="model-note">config</span>');
  assert.equal(row(1).className, "model-option chosen active");
  assert.equal(row(1).getAttribute("aria-selected"), "true");
  // No tooltip, no attribute; an id is text, never markup.
  assert.equal(row(4).hasAttribute("title"), false);
  assert.equal(row(4).innerHTML.replace(/<!--[^]*?-->/g, ""), '<span class="model-id">a&lt;b&gt;</span>');
  assert.equal(row(5).className, "model-option unavailable");
});

test("a search marks the matched letters, escaped; no match says so", () => {
  const p = picker();
  p.button.click();
  p.type("a<");
  assert.match(p.markup(), /<span class="model-host">box<\/span><span class="model-dot"> · <\/span><mark>a&lt;<\/mark>b&gt;<\/span>/);
  assert.equal(p.list.querySelector("mark b"), null);
  assert.equal(p.activeRow(), "box · a<b>");
  p.type("zzz-none");
  assert.deepEqual(p.rows(), []);
  assert.match(p.markup(), /^<div class="model-empty" role="presentation">Nothing matches<\/div>$/);
  assert.equal(p.input.hasAttribute("aria-activedescendant"), false);
});

test("a narrower search redraws the rows it keeps in place", () => {
  const p = picker();
  p.button.click();
  p.type("al");
  const first = p.list.querySelector("#model-option-0");
  p.type("alp");
  assert.ok(p.list.querySelector("#model-option-0") === first);
  assert.equal(first.textContent, "box · alphaconfig");
});

test("arrows and pages move the active row; Enter picks it, remembers it and closes", () => {
  const p = picker();
  p.button.click();
  assert.equal(p.activeRow(), "fakedefault");
  p.key("ArrowDown");
  assert.equal(p.activeRow(), "alphaconfig");
  assert.equal(p.list.querySelectorAll(".model-option.active").length, 1);
  assert.equal(p.list.querySelector(".model-option.active").getAttribute("aria-selected"), "true");
  p.key("ArrowUp");
  p.key("ArrowUp");
  p.key("ArrowUp");
  assert.equal(p.activeRow(), "zetahost down", "wraps");
  p.key("PageUp");
  assert.equal(p.activeRow(), "otherconfig");
  p.key("PageDown");
  assert.equal(p.activeRow(), "zetahost down");
  p.key("ArrowUp");
  p.key("ArrowUp");
  p.key("Enter");
  assert.deepEqual(p.picks, ["box:alpha"]);
  assert.equal(p.ctl.chosen(), "box:alpha");
  assert.equal(localStorage.getItem(MODEL_KEY), "box:alpha");
  assert.deepEqual(JSON.parse(localStorage.getItem(RECENT_KEY)), ["box:alpha"]);
  assert.equal(p.ctl.isOpen(), false);
  assert.equal(p.markup(), "");
  assert.equal(p.button.getAttribute("aria-expanded"), "false");
});

test("Esc closes without a change and gives the button the focus; Tab closes and leaves the focus to move", () => {
  const p = picker();
  p.button.click();
  p.key("ArrowDown");
  p.key("Escape");
  assert.equal(p.ctl.isOpen(), false);
  assert.equal(p.ctl.chosen(), "fake");
  assert.equal(document.activeElement, p.button);
  p.button.click();
  p.key("Tab");
  assert.equal(p.ctl.isOpen(), false);
  assert.deepEqual(p.picks, []);
});

test("ArrowDown on the button opens it; the pointer moves the active row and a click picks", () => {
  const p = picker();
  p.button.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
  assert.equal(p.ctl.isOpen(), true);
  const row = p.list.querySelector("#model-option-2 .model-id");
  row.dispatchEvent(new window.MouseEvent("mousemove", { bubbles: true }));
  assert.equal(p.activeRow(), "alphaconfig");
  row.click();
  assert.deepEqual(p.picks, ["box:alpha"]);
  assert.equal(p.ctl.isOpen(), false);
});

test("a press outside closes; the button toggles it", () => {
  const p = picker();
  p.button.click();
  document.body.dispatchEvent(new window.PointerEvent("pointerdown", { bubbles: true }));
  assert.equal(p.ctl.isOpen(), false);
  p.button.click();
  p.button.click();
  assert.equal(p.ctl.isOpen(), false);
  p.button.click();
  p.button.hidden = true;
  p.ctl.close();
  p.button.click();
  assert.equal(p.ctl.isOpen(), false, "a hidden button opens nothing");
});

test("show puts a name on the button and stores nothing; a name that isn't a row still shows, no row chosen", () => {
  const p = picker({ recent: ["other"] });
  p.ctl.show("box:alpha");
  assert.equal(p.button.textContent, "box:alpha");
  assert.equal(p.ctl.chosenRow().host, "box");
  p.ctl.show("openrouter:vendor/model");
  assert.equal(p.button.textContent, "openrouter:vendor/model");
  assert.equal(p.ctl.chosen(), "openrouter:vendor/model");
  assert.equal(p.ctl.chosenRow(), null);
  assert.equal(localStorage.getItem(MODEL_KEY), null);
  assert.equal(localStorage.getItem(RECENT_KEY), JSON.stringify(["other"]));
});

test("a pick with remember false runs onPick and stores neither the choice nor Recent", () => {
  const p = picker({ recent: ["other"], remember: () => false });
  p.button.click();
  p.type("alpha");
  p.key("Enter");
  assert.deepEqual(p.picks, ["box:alpha"]);
  assert.equal(p.button.textContent, "box:alpha");
  assert.equal(localStorage.getItem(MODEL_KEY), null);
  assert.equal(localStorage.getItem(RECENT_KEY), JSON.stringify(["other"]));
});

test("a pick by default stores the choice and puts it first in Recent", () => {
  const p = picker({ recent: ["other"] });
  p.button.click();
  p.type("alpha");
  p.key("Enter");
  assert.deepEqual(p.picks, ["box:alpha"]);
  assert.equal(localStorage.getItem(MODEL_KEY), "box:alpha");
  assert.deepEqual(JSON.parse(localStorage.getItem(RECENT_KEY)), ["box:alpha", "other"]);
});

test("restore goes back to the stored name while offered, else the default; nothing before the list", () => {
  const p = picker({ stored: "other" });
  p.ctl.show("box:alpha");
  p.ctl.restore("other");
  assert.equal(p.ctl.chosen(), "other");
  assert.equal(p.button.textContent, "other");
  p.ctl.show("box:alpha");
  p.ctl.restore(null);
  assert.equal(p.ctl.chosen(), "fake");
  p.ctl.restore("gone:x");
  assert.equal(p.ctl.chosen(), "fake");
  const q = picker({ payload: { models: [] } });
  q.ctl.restore("other");
  assert.equal(q.ctl.chosen(), "");
});
