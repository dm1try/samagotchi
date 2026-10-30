// The start page's 🧰 list (start_toolkit.js): its rows (Auto only with
// suggest on, the default marked, the built-ins worded), what a pick sends,
// the override chip's words, and the list in happy-dom (focus, ↑/↓, a pick
// closes it, a refusal). start_page.test.js covers it wired to the page.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  AUTO, createStartToolkit, listTemplate, pickValue, toolkitLabel, toolkitOverride, toolkitRows,
} from "../../../lib/samagotchi/web/public/start_toolkit.js";
import { markupOf } from "./dom_shim.js";

const KITS = [{ name: "full" }, { name: "lean" }, { name: "web", description: "browsing the web" }];
const ON = { default: "full", suggest: "on", kits: KITS };
const OFF = { default: "full", suggest: "off", kits: KITS };

const rowsText = (rows) => rows.map((r) => `${r.label}${r.pressed ? "*" : ""} — ${r.detail}`);

test("rows: Auto first with suggest on, checked by default; the kits after, the default marked, the built-ins worded", () => {
  assert.deepEqual(rowsText(toolkitRows(ON, null)), [
    "Auto* — may be picked on the first message, else full",
    "full — every tool · default",
    "lean — core tools; find_tools reaches the rest",
    "web — browsing the web",
  ]);
  assert.match(toolkitRows(ON, null)[1].title, /gets no suggestion/);
  assert.deepEqual(toolkitRows(ON, "web").map((r) => r.pressed), [false, false, false, true]);
  assert.deepEqual(toolkitRows(null, null), []);
});

test("rows without Auto (suggest off or audit): the default's row is checked when nothing is picked", () => {
  assert.deepEqual(rowsText(toolkitRows(OFF, null)).slice(0, 2), ["full* — every tool · default",
                                                                   "lean — core tools; find_tools reaches the rest"]);
  assert.equal(toolkitRows({ ...OFF, suggest: "audit" }, null)[0].label, "full");
  assert.equal(toolkitRows(OFF, null)[0].title, null);
  assert.equal(toolkitRows(OFF, null)[2].title, "browsing the web"); // a long one is cut in the row
  // A default chi web can't resolve (a bundle kit) is listed by the server, no words of its own.
  assert.equal(rowsText(toolkitRows({ default: "mine", suggest: "off", kits: [{ name: "mine" }, ...KITS] }, null))[0],
               "mine* — default");
});

test("a pick's value: Auto sends nothing; the default is sent while Auto is offered, else it is Auto's row", () => {
  assert.equal(pickValue(ON, AUTO), null);
  assert.equal(pickValue(ON, "full"), "full");
  assert.equal(pickValue(ON, "web"), "web");
  assert.equal(pickValue(OFF, "full"), null);
  assert.equal(pickValue(OFF, "lean"), "lean");
});

test("the override chip and 🧰's label name the kit picked", () => {
  assert.equal(toolkitOverride(null), null);
  assert.equal(toolkitOverride("web").text, "tools: web");
  assert.match(toolkitOverride("web").title, /^Toolkit: web for the new session/);
  assert.deepEqual(toolkitLabel(null), { set: false, label: "Toolkit" });
  assert.deepEqual(toolkitLabel("lean"), { set: true, label: "Toolkit: lean" });
});

test("the list: the review note only with suggest on and review files set; the error; the /toolkit note", () => {
  const plain = markupOf(listTemplate({ toolkits: ON, choice: null }));
  assert.match(plain, /Change it later with \/toolkit\./);
  assert.doesNotMatch(plain, /review session/);
  assert.match(markupOf(listTemplate({ toolkits: ON, choice: null, review: true })),
               /A review session gets no suggestion: it starts on full unless you pick a kit\./);
  assert.doesNotMatch(markupOf(listTemplate({ toolkits: OFF, choice: null, review: true })), /review session/);
  assert.doesNotMatch(markupOf(listTemplate({ toolkits: ON, choice: "web", review: true })), /review session/);
  assert.match(markupOf(listTemplate({ toolkits: ON, choice: "web", error: "bad groups" })), /bad groups/);
});

// A list in happy-dom over plain state, 🧰 on the body.
function list(t, { toolkits = ON, choice = null } = {}) {
  const button = document.createElement("button");
  button.id = "toolkitTest";
  document.body.append(button);
  const state = { choice, toolkits };
  const ctl = createStartToolkit({
    el: button, button, toolkits: () => state.toolkits, choice: () => state.choice,
    choose: (next) => { state.choice = next; }, win: { innerWidth: 1000, innerHeight: 800 },
  });
  const pop = [...document.querySelectorAll("#startToolkitPopover")].pop();
  t.after(() => { button.remove(); pop.remove(); });
  const row = (value) => pop.querySelector(`[data-act="kit:${value}"]`);
  const key = (k) => document.activeElement.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true }));
  return { button, ctl, pop, state, row, key };
}

test("open: focus on the checked row; ↑/↓ move between rows; a pick closes the list and focus goes back to 🧰", (t) => {
  const l = list(t, { choice: "lean" });
  l.button.click();
  assert.equal(l.pop.hidden, false);
  assert.equal(l.button.getAttribute("aria-expanded"), "true");
  assert.equal(l.pop.getAttribute("aria-label"), "Toolkit");
  assert.equal(l.pop.getAttribute("aria-modal"), "true");
  assert.ok(document.activeElement === l.row("lean"));
  l.key("ArrowDown");
  assert.ok(document.activeElement === l.row("web"));
  l.key("ArrowDown"); // the last row stays
  assert.ok(document.activeElement === l.row("web"));
  l.key("ArrowUp");
  l.key("ArrowUp");
  l.key("ArrowUp");
  assert.ok(document.activeElement === l.row(AUTO));
  l.row(AUTO).click();
  assert.equal(l.state.choice, null);
  assert.equal(l.pop.hidden, true);
  assert.equal(l.button.getAttribute("aria-expanded"), "false");
  assert.ok(document.activeElement === l.button);
  l.button.click();
  l.row("full").click();
  assert.equal(l.state.choice, "full"); // the default, sent: Auto is offered
});

test("refuse opens the list with the server's words; a pick clears them; nothing opens without toolkits", (t) => {
  const l = list(t, { choice: "web" });
  l.ctl.refuse("toolkit.kits.web: groups must be a name or a list");
  assert.equal(l.pop.hidden, false);
  assert.equal(l.pop.querySelector(".ctx-pop-error").textContent, "toolkit.kits.web: groups must be a name or a list");
  l.row("lean").click();
  l.button.click();
  assert.equal(l.pop.querySelector(".ctx-pop-error").hidden, true);
  l.ctl.close();
  l.state.toolkits = null;
  l.button.click();
  assert.equal(l.pop.hidden, true);
});
