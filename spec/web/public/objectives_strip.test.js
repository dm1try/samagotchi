import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createObjectivesStrip } from "../../../lib/samagotchi/web/public/objectives_strip.js";

const view = (over = {}) => ({ pending: false, items: [
  { id: "O1", text: "Two coffees", status: "done" }, { id: "O2", text: "Stops before checkout", status: "active" },
  { id: "O3", text: "Dropped one", status: "dropped" },
], ...over });

function strip({ running = false, sendLine = async () => {}, failed = () => {} } = {}) {
  document.getElementById("objectivesPanel")?.remove();
  const el = document.createElement("div");
  el.hidden = true;
  document.body.appendChild(el);
  const lines = [];
  const control = createObjectivesStrip({
    el, session: () => "s1", running: () => running, failed,
    sendLine: (line) => { lines.push(line); return sendLine(line); },
  });
  return { el, control, lines, pop: () => document.getElementById("objectivesPanel") };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("no list: the strip stays hidden and empty", () => {
  const { el, control } = strip();
  control.seed(undefined);
  assert.equal(el.hidden, true);
  assert.equal(el.querySelectorAll(".obj-chip").length, 0);
});

test("a list shows active first, without the dropped one, with its count, and an update redraws", () => {
  const { el, control } = strip();
  control.seed(view());
  assert.equal(el.hidden, false);
  assert.deepEqual([...el.querySelectorAll(".obj-chip .obj-id")].map((n) => n.textContent), ["O2", "O1"]);
  assert.equal(el.querySelector(".obj-count").textContent, "1/2");
  control.update(view({ items: [{ id: "O1", text: "Two coffees", status: "done" }] }));
  assert.equal(el.querySelector(".obj-count").textContent, "1/1");
  control.reset();
  assert.equal(el.hidden, true);
});

test("a chip opens the edit list; done, drop and undo post their lines", async () => {
  const { el, control, lines, pop } = strip();
  control.seed(view());
  el.querySelector('.obj-chip[data-id="O2"]').click();
  assert.equal(pop().hidden, false);
  pop().querySelector('[data-row="O2"] [data-obj-act="done"]').click();
  await settle();
  pop().querySelector('[data-row="O1"] [data-obj-act="undo"]').click();
  await settle();
  pop().querySelector('[data-row="O3"] [data-obj-act="undo"]').click();
  await settle();
  pop().querySelector('[data-row="O2"] [data-obj-act="drop"]').click();
  assert.deepEqual(lines, ["/objectives done O2", "/objectives undo O1", "/objectives undo O3", "/objectives drop O2"]);
  control.reset();
  assert.equal(pop().hidden, true);
});

test("a tap on the text edits it; Esc takes the edit back, Save posts it", async () => {
  const { el, control, lines, pop } = strip();
  control.seed(view());
  el.querySelector(".obj-edit").click();
  pop().querySelector('[data-row="O2"] .obj-row-text').click();
  const input = pop().querySelector('form[data-id="O2"] input');
  assert.equal(input.value, "Stops before checkout");
  input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.equal(pop().querySelector('form[data-id="O2"]'), null);
  assert.equal(pop().hidden, false);
  pop().querySelector('[data-row="O2"] .obj-row-text').click();
  pop().querySelector('form[data-id="O2"] input').value = "Stops at the cart";
  pop().querySelector('form[data-id="O2"]').dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await settle();
  assert.deepEqual(lines, ["/objectives edit O2 Stops at the cart"]);
  control.reset();
});

test("a waiting edit shows on the strip and in the list; a refused post reaches failed", async () => {
  const errors = [];
  const { el, control, pop } = strip({ running: true, sendLine: async () => { throw new Error("no"); }, failed: (e) => errors.push(e.message) });
  control.seed(view({ pending: true }));
  assert.equal(el.querySelector(".obj-waiting").textContent, "Applies after this turn");
  el.querySelector(".obj-edit").click();
  assert.equal(pop().querySelector(".obj-note").textContent, "Applies after this turn");
  pop().querySelector('[data-row="O2"] [data-obj-act="done"]').click();
  await settle();
  await settle();
  assert.deepEqual(errors, ["no"]);
  control.reset();
});

test("the first active objective is the phone's one chip", () => {
  const { el, control } = strip();
  control.seed(view());
  assert.deepEqual([...el.querySelectorAll(".obj-chip.first .obj-id")].map((n) => n.textContent), ["O2"]);
  control.reset();
});

test("Not yet sends one message, from a row with a move or by id; a row with no move has none", async () => {
  const sent = [];
  document.getElementById("objectivesPanel")?.remove();
  const el = document.createElement("div");
  document.body.appendChild(el);
  const control = createObjectivesStrip({ el, session: () => "s1", sendMessage: async (text) => { sent.push(text); } });
  control.seed({ pending: false, items: [
    { id: "O1", text: "Moved", status: "active", move: { note: "n", evidence: "" } }, { id: "O2", text: "Not moved", status: "active" },
  ] });
  el.querySelector(".obj-edit").click();
  const pop = document.getElementById("objectivesPanel");
  assert.equal(pop.querySelector('[data-row="O2"] [data-obj-act="notyet"]'), null);
  pop.querySelector('[data-row="O1"] [data-obj-act="notyet"]').click();
  control.notYet("O2");
  control.notYet("O9");
  await settle();
  assert.deepEqual(sent, ["Not yet on O1 (Moved).", "Not yet on O2 (Not moved)."]);
  control.reset();
});

test("Save with a blank text takes the edit back, and the panel stays", async () => {
  const { el, control, lines, pop } = strip();
  control.seed(view());
  el.querySelector(".obj-edit").click();
  pop().querySelector('[data-row="O2"] .obj-row-text').click();
  pop().querySelector('form[data-id="O2"] input').value = "   ";
  pop().querySelector('form[data-id="O2"]').dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await settle();
  assert.deepEqual(lines, []);
  assert.equal(pop().querySelector('form[data-id="O2"]'), null);
  assert.equal(pop().hidden, false);
  control.reset();
});

test("Not yet in the list: two taps send one message, and a failure lets it be tapped again", async () => {
  const sent = [];
  let fail = false;
  document.getElementById("objectivesPanel")?.remove();
  const el = document.createElement("div");
  document.body.appendChild(el);
  const control = createObjectivesStrip({ el, session: () => "s1", failed: () => {}, sendMessage: async (text) => { sent.push(text); if (fail) throw new Error("no"); } });
  control.seed({ pending: false, items: [{ id: "O1", text: "A", status: "active", move: { note: "n", evidence: "" } }] });
  el.querySelector(".obj-edit").click();
  const pop = document.getElementById("objectivesPanel");
  const tap = () => pop.querySelector('[data-obj-act="notyet"]');
  tap().click();
  tap().click();
  await settle();
  assert.equal(sent.length, 1);
  assert.equal(tap().disabled, true);
  control.reset();
  control.seed({ pending: false, items: [{ id: "O1", text: "A", status: "active", move: { note: "n", evidence: "" } }] });
  el.querySelector(".obj-edit").click();
  fail = true;
  assert.equal(await control.notYet("O1"), false);
  await settle();
  assert.equal(tap().disabled, false);
  control.reset();
});

test("Check this: only with a move; posts its line, and a running or finished check shows in the row", async () => {
  const { el, control, lines, pop } = strip();
  control.seed({ items: [{ id: "O1", text: "A", status: "active", move: { note: "did it", evidence: "" } },
                         { id: "O2", text: "B", status: "active" }], pending: false });
  el.querySelector(".obj-edit").click();
  assert.equal(pop().querySelector('[data-row="O2"] [data-obj-act="check"]'), null);
  pop().querySelector('[data-row="O1"] [data-obj-act="check"]').click();
  await settle();
  assert.deepEqual(lines, ["/objectives check O1"]);

  control.update({ items: [{ id: "O1", text: "A", status: "active", move: { note: "did it", evidence: "" }, check: { running: true } }], pending: false });
  assert.equal(pop().querySelector('[data-row="O1"] .obj-check').textContent, "Checking…");
  assert.equal(pop().querySelector('[data-row="O1"] [data-obj-act="check"]').disabled, true);

  control.update({ items: [{ id: "O1", text: "A", status: "active", move: { note: "did it", evidence: "" },
                             check: { verdict: "refuted", reason: "no suite ran", model: "main:x" } }], pending: false });
  const row = pop().querySelector('[data-row="O1"]');
  assert.equal(row.querySelector(".obj-check").textContent, "Check: refuted — no suite ran");
  assert.match(row.querySelector(".obj-check").title, /main:x/);
  assert.equal(row.querySelector('[data-obj-act="check"]').disabled, false);
});

test("a check on a dropped objective isn't offered", () => {
  const { el, control, pop } = strip();
  control.seed({ items: [{ id: "O1", text: "A", status: "dropped", move: { note: "x", evidence: "" } }, { id: "O2", text: "B", status: "active" }], pending: false });
  el.querySelector(".obj-edit").click();
  assert.equal(pop().querySelector('[data-row="O1"] [data-obj-act="check"]'), null);
});

test("a running check lets go when it expires, with no event: the row goes and the button is back", async () => {
  const { el, control, pop } = strip();
  const item = { id: "O1", text: "A", status: "active", move: { note: "did it", evidence: "" } };
  control.seed({ items: [{ ...item, check: { running: true, until: new Date(Date.now() + 30).toISOString() } }], pending: false });
  el.querySelector(".obj-edit").click();
  assert.equal(pop().querySelector('[data-row="O1"] .obj-check').textContent, "Checking…");
  await new Promise((resolve) => setTimeout(resolve, 80));
  assert.equal(pop().querySelector('[data-row="O1"] .obj-check'), null);
  assert.equal(pop().querySelector('[data-row="O1"] [data-obj-act="check"]').disabled, false);
  control.reset();
});

test("a check's start or end doesn't bring Not yet back: only a change to the list does", async () => {
  const sent = [];
  document.body.innerHTML = "";
  const host = document.createElement("div");
  document.body.appendChild(host);
  const control = createObjectivesStrip({ el: host, session: () => "s1", sendMessage: async (text) => sent.push(text) });
  const item = { id: "O1", text: "A", status: "active", move: { note: "did it", evidence: "" } };
  control.seed({ items: [item], pending: false });
  await control.notYet("O1");
  control.update({ items: [{ ...item, check: { running: true, until: new Date(Date.now() + 9000).toISOString() } }], pending: false });
  assert.equal(await control.notYet("O1"), false);
  control.update({ items: [{ ...item, check: { verdict: "confirmed", reason: "r" } }], pending: false });
  assert.equal(await control.notYet("O1"), false);
  assert.equal(sent.length, 1);
  control.update({ items: [{ ...item, move: { note: "newer", evidence: "" } }], pending: false });
  assert.equal(await control.notYet("O1"), true);
  control.reset();
});
