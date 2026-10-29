// The start page's model picker glue (start_page.js), in happy-dom over the
// real picker and ⚙ panel: the models' load, a fresh link's picker and its
// /model, the new session's own choices and their override chips. The
// picker's list is model_picker.test.js', the panel's rows start_settings'.
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
    { name: "openrouter:vendor/model:Q4", host: "openrouter", id: "vendor/model:Q4" },
  ],
  toolkits: { default: "full", suggest: "on", kits: [{ name: "full" }, { name: "lean" }] },
};

// A fresh chain link's state (chains.js freshLink): it continues one, no turn yet.
const freshLinkState = (model = "fake") => ({ continues: "prev", model, timing: { turnRecords: [] } });

// +t+: the test, whose end takes the page away (the chips' popovers are on
// the shared document's body: the files after this one look theirs up by id).
function page(t, { listModels = async () => PAYLOAD, stored = null, run = async () => true, review = true } = {}) {
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
    ><button id="thinkingNew" hidden></button><button id="llmContextNew" hidden></button
    >${review ? `<button id="reviewNew" hidden></button>` : ""}<button id="toolkitNew" hidden></button><button id="settingsNew" hidden></button
    ><button id="toolkitBtn" hidden></button></div></div>`;
  const $ = (sel) => document.querySelector(sel);
  const world = { selected: null, state: {}, running: false, sessions: [] };
  const toasts = [];
  const ran = [];
  let focused = 0;
  const win = new EventTarget();
  const startPage = createStartPage({
    pickEl: $("#modelPick"), panelEl: $("#modelPanel"), searchEl: $("#modelSearch"), listEl: $("#modelList"),
    composerEl: $("#composer"), centerEl: $("#center"), settingsEl: $("#settingsNew"), llmContextEl: $("#llmContextNew"),
    thinkingEl: $("#thinkingNew"), reviewEl: $("#reviewNew"), toolkitBtnEl: $("#toolkitBtn"), toolkitEl: $("#toolkitNew"),
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
    llmChip: $("#llmContextNew"), thinkChip: $("#thinkingNew"), reviewChip: $("#reviewNew"), gear: $("#settingsNew"),
    panel: () => document.getElementById("startSettingsPopover"),
    kitBtn: $("#toolkitBtn"), kitChip: $("#toolkitNew"),
    kitList: () => document.getElementById("startToolkitPopover"),
    // A click on the 🧰 list's row for +value+.
    kit: (value) => document.querySelector(`#startToolkitPopover [data-act="kit:${value}"]`).click(),
    // A click on the panel's button whose data-act is +act+.
    act: (act) => document.querySelector(`#startSettingsPopover [data-act="${act}"]`).click(),
  };
}

test("loadModels: the button shows with the stored choice; ⚙'s rows follow the picked model's values", async (t) => {
  const p = page(t, { stored: "qwen" });
  assert.equal(p.button.hidden, true);
  assert.equal(p.startPage.chosenModel(), undefined); // the server's default while the list is not in
  await p.startPage.loadModels();
  assert.equal(p.button.hidden, false);
  assert.equal(p.name(), "qwen");
  assert.equal(p.button.title, `${START_PICK_TITLE} · qwen`);
  assert.equal(p.button.getAttribute("aria-label"), "Model for the new session: qwen");
  assert.equal(p.startPage.chosenModel(), "qwen");
  // Nothing set: no override chip, ⚙ plain.
  assert.equal(p.thinkChip.hidden, true);
  assert.equal(p.llmChip.hidden, true);
  assert.equal(p.gear.hidden, false);
  assert.equal(p.gear.classList.contains("set"), false);
  p.gear.click();
  const pressed = () => [...p.panel().querySelectorAll("[aria-pressed=true]")].map((b) => b.textContent);
  assert.deepEqual(pressed(), ["default (off)", "default (stale)"]);
  // A model without values hides the rows (the picker's click closed the panel).
  p.pick("fake");
  assert.equal(p.startPage.chosenModel(), "fake");
  assert.equal(p.panel().hidden, true);
  p.gear.click();
  assert.deepEqual(pressed(), []);
  assert.ok(p.panel().querySelector("[data-act=review]"));
  assert.deepEqual(p.ran, []);
  assert.equal(p.focused(), 1);
});

test("loadModels: a host's warning goes into the tooltip; an empty list leaves the button hidden", async (t) => {
  const p = page(t, { listModels: async () => ({ ...PAYLOAD, warning: "box: down" }) });
  await p.startPage.loadModels();
  assert.equal(p.button.title, `${START_PICK_TITLE} · box: down · fake`);
  const empty = page(t, { listModels: async () => ({ models: [] }) });
  await empty.startPage.loadModels();
  assert.equal(empty.button.hidden, true);
});

test("start-page model labels keep the full model name in their title and accessible name", async (t) => {
  const fullName = "openrouter:vendor/model:Q4";
  const p = page(t);
  await p.startPage.loadModels();
  p.pick("vendor/model:Q4");
  assert.equal(p.startPage.chosenModel(), fullName);
  assert.equal(p.name(), "openrouter · model:Q4");
  assert.equal(p.button.title, `${START_PICK_TITLE} · ${fullName}`);
  assert.equal(p.button.getAttribute("aria-label"), `Model for the new session: ${fullName}`);
  p.startPage.syncModelPick();
  assert.equal(p.button.title, `${START_PICK_TITLE} · ${fullName}`);
  p.startPage.restoreStartPick();
  assert.equal(p.name(), "openrouter · model:Q4");
  assert.equal(p.button.title, `${START_PICK_TITLE} · ${fullName}`);
  assert.equal(p.button.getAttribute("aria-label"), `Model for the new session: ${fullName}`);
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
  assert.deepEqual(p.startPage.newChoices(), { llm_context: undefined, thinking: undefined, review: undefined,
                                               toolkit: undefined });
  p.gear.click();
  p.act("think:high");
  // A pick applies at once, the panel stays open, the focus stays in it.
  assert.equal(p.panel().hidden, false);
  assert.equal(p.focused(), 0);
  assert.equal(p.startPage.newChoices().thinking, "high");
  assert.equal(p.thinkChip.hidden, false);
  assert.equal(p.thinkChip.textContent, "think high");
  p.act("ctx:stale,forget");
  assert.deepEqual(p.startPage.newChoices().llm_context, { strategy: "stale,forget" });
  assert.equal(p.llmChip.textContent, "ctx stale,forget");
  assert.equal(p.gear.classList.contains("set"), true);
  assert.equal(p.gear.getAttribute("aria-label"), "Session settings: think high, ctx stale,forget");
  p.startPage.clearChoices();
  assert.equal(p.startPage.newChoices().thinking, undefined);
  assert.equal(p.startPage.newChoices().llm_context, undefined);
  assert.equal(p.thinkChip.hidden, true);
  assert.equal(p.gear.classList.contains("set"), false);
  assert.equal(p.gear.getAttribute("aria-label"), "Session settings");
  p.act("think:low");
  p.world.selected = "s1";
  p.startPage.dropChoices();
  assert.equal(p.startPage.newChoices().thinking, undefined);
  assert.equal(p.panel().hidden, true);
  assert.equal(p.thinkChip.hidden, true);
});

test("an override chip opens the panel (the review chip on its view); focus goes back to ⚙ on Esc", async (t) => {
  const p = page(t, { stored: "qwen" });
  await p.startPage.loadModels();
  p.gear.click();
  p.act("think:medium");
  p.gear.click(); // a second click closes
  assert.equal(p.panel().hidden, true);
  p.thinkChip.click();
  assert.equal(p.panel().hidden, false);
  assert.equal(document.activeElement.textContent, "medium");
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.equal(p.panel().hidden, true);
  assert.ok(document.activeElement === p.gear);
  // The review row: its view, Set returns to the settings with the files chosen.
  p.gear.click();
  p.act("review");
  const form = p.panel().querySelector("form.rs-form");
  form.elements.subjects.value = "docs/plan.md, README.md";
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  assert.deepEqual(p.startPage.reviewSubjects(), ["docs/plan.md", "README.md"]);
  assert.equal(p.panel().querySelector("form.rs-form"), null);
  assert.equal(p.reviewChip.hidden, false);
  assert.equal(p.reviewChip.textContent, "review: plan.md +1");
  p.act("close");
  p.reviewChip.click();
  assert.ok(p.panel().querySelector("form.rs-form"));
  assert.ok(document.activeElement === p.panel().querySelector("textarea"));
});

test("Start's refusal of the review files opens the panel's review view with the server's words", async (t) => {
  const p = page(t);
  await p.startPage.loadModels();
  assert.equal(p.startPage.reviewRefused("nope"), false); // no files set: the caller's alert
  p.gear.click();
  p.act("review");
  const form = p.panel().querySelector("form.rs-form");
  form.elements.subjects.value = ".env";
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  p.act("close");
  assert.equal(p.startPage.reviewRefused(".env can't be a review subject: it may hold secrets"), true);
  assert.equal(p.panel().hidden, false);
  assert.equal(p.panel().querySelector(".ctx-pop-error").textContent, ".env can't be a review subject: it may hold secrets");
  assert.equal(p.panel().querySelector("textarea").value, ".env");
});

test("a choice the picked model can't show stays: its chip says it is sent anyway, and it is sent", async (t) => {
  const p = page(t, { stored: "qwen" });
  await p.startPage.loadModels();
  p.gear.click();
  p.act("think:high");
  p.pick("fake");
  assert.equal(p.startPage.newChoices().thinking, "high");
  assert.equal(p.thinkChip.hidden, false);
  assert.match(p.thinkChip.title, /the picked model has no thinking setting; it is sent anyway/);
  assert.equal(p.gear.classList.contains("set"), true);
  // The panel has no Thinking row then, but says so and can clear it.
  p.thinkChip.click();
  assert.match(p.panel().querySelector(".ss-anyway").textContent, /Thinking high: the picked model has no thinking setting/);
  p.act("think-clear");
  assert.equal(p.startPage.newChoices().thinking, undefined);
  assert.equal(p.thinkChip.hidden, true);
});

test("without the models list ⚙ holds the review files only; without those either it is hidden", async (t) => {
  const failing = async () => { throw Object.assign(new Error("boom"), { status: 500 }); };
  const p = page(t, { listModels: failing });
  await p.startPage.loadModels();
  assert.equal(p.gear.hidden, false);
  p.gear.click();
  assert.equal(p.panel().querySelector(".ss-row"), null);
  assert.ok(p.panel().querySelector("[data-act=review]"));
  const bare = page(t, { listModels: failing, review: false });
  await bare.startPage.loadModels();
  assert.equal(bare.gear.hidden, true);
});

test("🧰: a kit picked is sent with the create, its chip and dot show; cleared after, dropped on opening a session", async (t) => {
  const p = page(t);
  assert.equal(p.kitBtn.hidden, true); // until the list is in
  await p.startPage.loadModels();
  assert.equal(p.kitBtn.hidden, false);
  assert.equal(p.kitChip.hidden, true);
  assert.equal(p.kitBtn.getAttribute("aria-label"), "Toolkit");
  p.kitBtn.click();
  assert.equal(document.activeElement.dataset.act, "kit:auto"); // Auto, checked
  p.kit("lean");
  assert.equal(p.kitList().hidden, true); // a pick closes it
  assert.ok(document.activeElement === p.kitBtn);
  assert.equal(p.startPage.newChoices().toolkit, "lean");
  assert.equal(p.kitChip.hidden, false);
  assert.equal(p.kitChip.textContent, "tools: lean");
  assert.equal(p.kitBtn.classList.contains("set"), true);
  assert.equal(p.kitBtn.getAttribute("aria-label"), "Toolkit: lean");
  assert.equal(p.focused(), 0);
  // The chip opens the list again; Auto sends nothing.
  p.kitChip.click();
  assert.equal(p.kitList().hidden, false);
  p.kit("auto");
  assert.equal(p.startPage.newChoices().toolkit, undefined);
  assert.equal(p.kitChip.hidden, true);
  p.kitBtn.click();
  p.kit("full");
  p.startPage.clearChoices();
  assert.equal(p.startPage.newChoices().toolkit, undefined);
  assert.equal(p.kitBtn.classList.contains("set"), false);
  p.kitBtn.click();
  p.kit("lean");
  p.kitBtn.click();
  p.world.selected = "s1";
  p.startPage.dropChoices();
  assert.equal(p.startPage.newChoices().toolkit, undefined);
  assert.equal(p.kitList().hidden, true);
});

test("🧰 is hidden without the payload's toolkits; Start's refusal of a picked kit opens the list with its words", async (t) => {
  const failing = async () => { throw Object.assign(new Error("boom"), { status: 500 }); };
  const down = page(t, { listModels: failing });
  await down.startPage.loadModels();
  assert.equal(down.kitBtn.hidden, true);
  const old = page(t, { listModels: async () => ({ ...PAYLOAD, toolkits: undefined }) });
  await old.startPage.loadModels();
  assert.equal(old.kitBtn.hidden, true);
  assert.equal(old.startPage.toolkitRefused("broken"), false);
  const p = page(t);
  await p.startPage.loadModels();
  assert.equal(p.startPage.toolkitRefused("broken default"), false); // nothing picked: config's default, the alert
  p.kitBtn.click();
  p.kit("lean");
  assert.equal(p.startPage.toolkitRefused("toolkit.kits.lean: bad groups"), true);
  assert.equal(p.kitList().hidden, false);
  assert.equal(p.kitList().querySelector(".ctx-pop-error").textContent, "toolkit.kits.lean: bad groups");
  assert.equal(p.startPage.newChoices().toolkit, "lean"); // a failed create keeps it
});
