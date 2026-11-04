import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createObjectives } from "../../../lib/samagotchi/web/public/objectives_wiring.js";

globalThis.MutationObserver ??= window.MutationObserver;

function wired(over = {}) {
  document.getElementById("objectivesPanel")?.remove();
  const el = document.createElement("div");
  const historyEl = document.createElement("div");
  document.body.append(el, historyEl);
  const seen = { lines: [], turns: [], woke: 0, toasts: [] };
  let open = "s1";
  const objectives = createObjectives({
    el, historyEl, session: () => open, running: () => false, commands: () => [{ name: "/short" }], clientId: "web:me",
    sendCommand: async (id, line, opts) => { seen.lines.push([id, line, opts]); },
    sendTurn: async (id, text, opts) => { seen.turns.push([id, text, opts]); },
    follow: () => { seen.woke += 1; }, toast: (text) => seen.toasts.push(text),
    ...over,
  });
  return { el, historyEl, objectives, seen, switchTo: (id) => { open = id; } };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const list = { pending: false, items: [{ id: "O1", text: "A", status: "active" }] };

test("an edit follows the worker it woke, unless the page moved on", async () => {
  const { el, objectives, seen, switchTo } = wired();
  objectives.seed(list);
  el.querySelector(".obj-edit").click();
  const done = () => document.getElementById("objectivesPanel").querySelector('[data-obj-act="done"]');
  done().click();
  await settle();
  assert.deepEqual(seen.lines[0], ["s1", "/objectives done O1", { clientId: "web:me", card: true }]);
  assert.equal(seen.woke, 1);
  done().click();
  switchTo("s2");
  await settle();
  assert.equal(seen.woke, 1);
  objectives.reset();
});

test("Not yet goes as a message of its own client id, followed only on the same session", async () => {
  const { objectives, seen, switchTo } = wired();
  objectives.seed(list);
  assert.equal(await objectives.notYet("O1"), true);
  assert.equal(seen.turns[0][2].clientId, "web:me:objectives");
  assert.equal(seen.woke, 1);
  objectives.reset();
  objectives.seed(list);
  const going = objectives.notYet("O1");
  switchTo("s2");
  await going;
  assert.equal(seen.woke, 1);
  objectives.reset();
});

test("Short version shows only with a list, the command, no running turn and none in the stage; a failed ask toasts and comes back", async () => {
  let running = false;
  let holding = false;
  const { historyEl, objectives, seen } = wired({
    running: () => running, holding: () => holding, sendCommand: async () => { throw new Error("no"); },
  });
  historyEl.innerHTML = '<div class="bubble output"></div>';
  historyEl.querySelector(".bubble.output").textContent = "x".repeat(3000);
  objectives.redraw();
  assert.equal(historyEl.querySelector(".obj-short"), null);
  objectives.seed(list);
  const button = historyEl.querySelector(".obj-short button");
  assert.ok(button);
  running = true;
  objectives.redraw();
  assert.equal(historyEl.querySelector(".obj-short"), null);
  running = false;
  holding = true;
  objectives.redraw();
  assert.equal(historyEl.querySelector(".obj-short"), null);
  holding = false;
  objectives.redraw();
  historyEl.querySelector(".obj-short button").click();
  await settle();
  await settle();
  assert.equal(seen.toasts.length, 1);
  assert.equal(historyEl.querySelector(".obj-short button").disabled, false);
  objectives.reset();
});
