// The start page's model picker glue (start_page.js), in happy-dom over the
// real picker and chips: the models' load, a fresh link's picker and its
// /model, the new session's own choices. The picker's list is
// model_picker.test.js', the chips' forms llm_context_chip/thinking_chip's.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

const { createStartPage, START_PICK_TITLE } = await import("../../../lib/samagotchi/web/public/start_page.js");
const { MODEL_KEY } = await import("../../../lib/samagotchi/web/public/model_pick.js");

const THINKING = { level: "off", source: "models: qwen", own: null };
const LLM_CONTEXT = {
  strategy: "stale", strategy_source: "model_setting", strategy_where: "models: qwen",
  apply: "payoff", apply_source: "config", apply_where: "llm_context.apply",
  budget_tokens: null, budget_source: "config", budget_where: "llm_context.budget_tokens", own: null,
};
const PAYLOAD = {
  default: "fake",
  models: [
    { name: "fake", id: "fake" },
    { name: "qwen", id: "qwen", thinking: THINKING, llm_context: LLM_CONTEXT },
  ],
};

// A fresh chain link's state (chains.js freshLink): it continues one, no turn yet.
const freshLinkState = (model = "fake") => ({ continues: "prev", model, timing: { turnRecords: [] } });

// +t+: the test, whose end takes the page away (the chips' popovers are on
// the shared document's body: the files after this one look theirs up by id).
function page(t, { listModels = async () => PAYLOAD, stored = null, run = async () => true } = {}) {
  t.after(() => {
    document.body.innerHTML = "";
    document.body.className = "";
    localStorage.removeItem(MODEL_KEY);
  });
  localStorage.removeItem(MODEL_KEY);
  if (stored) localStorage.setItem(MODEL_KEY, stored);
  document.body.className = "";
  document.body.innerHTML = `<div id="center"><div id="composer"><div id="modelPanel" hidden><input id="modelSearch"
    ><div id="modelList"></div></div><button id="modelPick" hidden><span class="model-pick-name"></span></button
    ><button id="llmContextNew" hidden></button><button id="thinkingNew" hidden></button></div></div>`;
  const $ = (sel) => document.querySelector(sel);
  const world = { selected: null, state: {}, running: false, sessions: [] };
  const toasts = [];
  const ran = [];
  let focused = 0;
  const win = new EventTarget();
  const startPage = createStartPage({
    pickEl: $("#modelPick"), panelEl: $("#modelPanel"), searchEl: $("#modelSearch"), listEl: $("#modelList"),
    composerEl: $("#composer"), centerEl: $("#center"), llmContextEl: $("#llmContextNew"), thinkingEl: $("#thinkingNew"),
    selected: () => world.selected,
    state: () => world.state,
    running: () => world.running,
    sessions: () => world.sessions,
    run: (line) => { ran.push(line); return run(line); },
    focusPrompt: () => { focused += 1; },
    toast: (text) => toasts.push(text),
    listModels,
    win,
  });
  // A click on the list's row named +name+ (the panel opened first).
  const pick = (name) => {
    $("#modelPick").click();
    const row = [...$("#modelList").querySelectorAll(".model-option")].find((el) => el.textContent.includes(name));
    row.click();
  };
  return {
    startPage, world, toasts, ran, win, pick, focused: () => focused,
    button: $("#modelPick"), name: () => $(".model-pick-name").textContent,
    llmChip: $("#llmContextNew"), thinkChip: $("#thinkingNew"),
  };
}

test("loadModels: the button shows with the stored choice, its chips follow the picked model's values", async (t) => {
  const p = page(t, { stored: "qwen" });
  assert.equal(p.button.hidden, true);
  assert.equal(p.startPage.chosenModel(), undefined); // the server's default while the list is not in
  await p.startPage.loadModels();
  assert.equal(p.button.hidden, false);
  assert.equal(p.name(), "qwen");
  assert.equal(p.button.title, START_PICK_TITLE);
  assert.equal(p.button.getAttribute("aria-label"), "Model for the new session");
  assert.equal(p.startPage.chosenModel(), "qwen");
  assert.equal(p.thinkChip.hidden, false);
  assert.equal(p.thinkChip.textContent, "think off");
  assert.equal(p.llmChip.hidden, false);
  assert.match(p.llmChip.textContent, /^llm ctx stale/);
  // A model without values hides the chips.
  p.pick("fake");
  assert.equal(p.startPage.chosenModel(), "fake");
  assert.equal(p.thinkChip.hidden, true);
  assert.equal(p.llmChip.hidden, true);
  assert.deepEqual(p.ran, []);
  assert.equal(p.focused(), 1);
});

test("loadModels: a host's warning goes into the tooltip; an empty list leaves the button hidden", async (t) => {
  const p = page(t, { listModels: async () => ({ ...PAYLOAD, warning: "box: down" }) });
  await p.startPage.loadModels();
  assert.equal(p.button.title, `${START_PICK_TITLE} · box: down`);
  const empty = page(t, { listModels: async () => ({ models: [] }) });
  await empty.startPage.loadModels();
  assert.equal(empty.button.hidden, true);
});

test("loadModels: a failed list is a toast on the start page, none in a session or while the page unloads", async (t) => {
  const failing = async () => { throw Object.assign(new Error("boom"), { status: 500 }); };
  const p = page(t, { listModels: failing });
  await p.startPage.loadModels();
  assert.equal(p.toasts.length, 1);
  assert.match(p.toasts[0], /A new session starts on the default model\.$/);
  assert.equal(p.button.hidden, true);
  p.world.selected = "s1";
  await p.startPage.loadModels();
  assert.equal(p.toasts.length, 1);
  await p.startPage.loadModels({ asked: true }); // + new session's load says it from a session too
  assert.equal(p.toasts.length, 2);
  p.world.selected = null;
  p.win.dispatchEvent(new Event("pagehide"));
  await p.startPage.loadModels();
  assert.equal(p.toasts.length, 2);
  p.win.dispatchEvent(new Event("pageshow")); // back from the bfcache
  await p.startPage.loadModels();
  assert.equal(p.toasts.length, 3);
});

test("syncModelPick: a fresh link shows its own model and title; the start page's choice comes back after", async (t) => {
  const p = page(t, { stored: "qwen" });
  await p.startPage.loadModels();
  p.world.selected = "s1";
  p.world.state = freshLinkState("fake");
  p.startPage.syncModelPick();
  assert.equal(document.body.classList.contains("fresh-link"), true);
  assert.equal(p.name(), "fake");
  assert.equal(p.button.title, "The model this link starts on");
  assert.equal(p.button.getAttribute("aria-label"), "Model this link starts on");
  // A link continued already (a next link in the list) is not fresh.
  p.world.sessions = [{ id: "s1", continues: "prev" }, { id: "s2", continues: "s1" }];
  p.startPage.syncModelPick();
  assert.equal(document.body.classList.contains("fresh-link"), false);
  assert.equal(p.button.title, START_PICK_TITLE);
  // Back on the start page: the remembered model, without a fetch.
  p.world.selected = null;
  p.startPage.restoreStartPick();
  assert.equal(p.name(), "qwen");
});

test("syncModelPick: the open panel closes when the page moves to another session", async (t) => {
  const p = page(t);
  await p.startPage.loadModels();
  p.startPage.syncModelPick();
  p.button.click();
  assert.equal(document.getElementById("modelPanel").hidden, false);
  p.world.selected = "s1";
  p.startPage.syncModelPick();
  assert.equal(document.getElementById("modelPanel").hidden, true);
});

test("a pick on a fresh link runs /model there; a send waits for it; refused, the button goes back", async (t) => {
  let answer;
  const p = page(t, { run: () => new Promise((resolve) => { answer = resolve; }) });
  await p.startPage.loadModels();
  p.world.selected = "s1";
  p.world.state = freshLinkState("fake");
  p.startPage.syncModelPick();
  p.pick("qwen");
  assert.deepEqual(p.ran, ["/model qwen"]);
  const pending = p.startPage.pendingPick();
  assert.ok(pending instanceof Promise);
  // While in flight a sync keeps the picked name (its command_ran syncs again).
  p.startPage.syncModelPick();
  assert.equal(p.name(), "qwen");
  answer(false);
  assert.equal(await pending, false);
  assert.equal(p.startPage.pendingPick(), null);
  assert.equal(p.name(), "fake");
});

test("a command_ran while the pick is in flight: its ack syncs the button then", async (t) => {
  let answer;
  const p = page(t, { run: () => new Promise((resolve) => { answer = resolve; }) });
  await p.startPage.loadModels();
  p.world.selected = "s1";
  p.world.state = freshLinkState("fake");
  p.startPage.syncModelPick();
  p.pick("qwen");
  const pending = p.startPage.pendingPick();
  p.world.state = freshLinkState("qwen:latest"); // the worker's own name for it
  p.startPage.commandRan();
  assert.equal(p.name(), "qwen"); // skipped while in flight
  answer(true);
  await pending;
  assert.equal(p.name(), "qwen:latest");
  // No pick in flight: a command_ran syncs at once.
  p.world.state = freshLinkState("other");
  p.startPage.commandRan();
  assert.equal(p.name(), "other");
});

test("the new session's choices: sent with the create, then cleared; opening a session drops them", async (t) => {
  const p = page(t, { stored: "qwen" });
  await p.startPage.loadModels();
  assert.deepEqual(p.startPage.newChoices(), { llm_context: undefined, thinking: undefined, review: undefined });
  // The thinking chip's form, on the start page: a level for the next session.
  const choose = (level) => {
    p.thinkChip.click();
    const pop = document.getElementById("thinkingNewPopover");
    pop.querySelector("select").value = level;
    pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  };
  choose("high");
  assert.equal(p.startPage.newChoices().thinking, "high");
  assert.equal(p.thinkChip.textContent, "think high · new session");
  assert.equal(p.focused(), 1);
  p.startPage.clearChoices();
  assert.equal(p.startPage.newChoices().thinking, undefined);
  assert.equal(p.thinkChip.textContent, "think off");
  choose("low");
  p.world.selected = "s1";
  p.startPage.dropChoices();
  assert.equal(p.startPage.newChoices().thinking, undefined);
  assert.equal(p.thinkChip.hidden, true); // in a session the start page's chips hide
});
