// The composer's mode (composer_mode.js): the pure model's four branches
// (start page, running, a terminal's session, idle) on a wide and a narrow
// screen, and the DOM apply's order: the has-session toggle's hooks first,
// the button left alone while a turn runs, #history emptied on the start
// page only.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { SEND_HINT, composerMode, createComposerMode } from "../../../lib/samagotchi/web/public/composer_mode.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

test("the start page: Start, its own hint, the empty state and an emptied history", () => {
  for (const narrow of [false, true]) {
    assert.deepEqual(composerMode({ selected: null, owner: null, running: false, narrow }), {
      placeholder: "Ask chi anything…", hint: "Enter to start · Shift+Enter for a newline", button: "Start", disabled: false,
      empty: true, clearHistory: true, attachHidden: false, delivery: "off",
    });
  }
  // A running flag without a session is the start page still.
  assert.equal(composerMode({ selected: null, running: true, narrow: true }).button, "Start");
});

test("a running turn: steering's placeholder, Send, the button left as it is; a phone hides attach", () => {
  const wide = composerMode({ selected: "s1", owner: "worker", running: true, narrow: false });
  assert.deepEqual(wide, {
    placeholder: "Running… a message goes in at the next step · Enter to send · Alt+Enter queues",
    hint: SEND_HINT, button: "Send", disabled: undefined, empty: false, clearHistory: false, attachHidden: false,
    delivery: "running",
  });
  const narrow = composerMode({ selected: "s1", owner: "worker", running: true, narrow: true });
  assert.equal(narrow.placeholder, "Steer the turn…");
  assert.equal(narrow.attachHidden, true);
  // A terminal's session while its turn runs: the running words, attach and the row off.
  const tui = composerMode({ selected: "s1", owner: "tui", running: true, narrow: false });
  assert.equal(tui.disabled, undefined);
  assert.equal(tui.attachHidden, true);
  assert.equal(tui.delivery, "off");
});

test("a session a terminal owns: no sending from here, no hint, no attach, the row off", () => {
  assert.deepEqual(composerMode({ selected: "s1", owner: "tui", running: false, narrow: false }), {
    placeholder: "A terminal chi owns this session · a one-turn chi --non-interactive run or an older chi's terminal",
    hint: "", button: "Send", disabled: true, empty: false, clearHistory: false, attachHidden: true, delivery: "off",
  });
  assert.equal(composerMode({ selected: "s1", owner: "tui", running: false, narrow: true }).placeholder,
    "A terminal chi owns this session");
});

test("an idle session: Message chi…, Send enabled, the delivery row idle", () => {
  for (const narrow of [false, true]) {
    assert.deepEqual(composerMode({ selected: "s1", owner: "worker", running: false, narrow }), {
      placeholder: "Message chi…", hint: SEND_HINT, button: "Send", disabled: false, empty: false, clearHistory: false,
      attachHidden: false, delivery: "idle",
    });
  }
});

function harness({ narrow = false } = {}) {
  const log = [];
  const listeners = [];
  const media = { matches: narrow, addEventListener: (_type, fn) => listeners.push(fn) };
  const el = (tag) => document.createElement(tag);
  const els = { body: el("div"), prompt: el("textarea"), hint: el("div"), button: el("button"), attach: el("button"),
                empty: el("div"), history: el("div") };
  els.history.append(el("p"));
  const store = createSessionStore({ initial: { owner: null } });
  const liveTurn = { running: false };
  let sheetOpen = true;
  const mode = createComposerMode({
    els, store, liveTurn,
    startPage: {
      restoreStartPick: () => log.push("restoreStartPick"),
      syncModelPick: () => log.push("syncModelPick"),
      dropChoices: () => log.push("dropChoices"),
    },
    deliveryControl: { show: (m) => log.push(`delivery ${m}`) },
    moreSheet: { isOpen: () => sheetOpen, close: () => { sheetOpen = false; log.push("closeSheet"); } },
    fitPrompt: () => log.push("fitPrompt"),
    placeToast: () => log.push("placeToast"),
    win: { matchMedia: () => media },
  });
  return { mode, els, store, liveTurn, log, media, listeners, isSheetOpen: () => sheetOpen };
}

test("the apply: the has-session toggle's hooks run first, and only when it flips", () => {
  const h = harness();
  h.store.update({ selected: "s1", current: { owner: "worker" } });
  h.mode.update();
  assert.deepEqual(h.log, ["fitPrompt", "placeToast", "syncModelPick", "dropChoices", "delivery idle"]);
  assert.ok(h.els.body.classList.contains("has-session"));
  assert.equal(h.els.history.children.length, 1, "a session's history is left alone");
  assert.ok(h.els.empty.classList.contains("hidden"));
  h.log.length = 0;
  h.mode.update();
  assert.deepEqual(h.log, ["syncModelPick", "dropChoices", "delivery idle"]);
  // Back on the start page: the remembered model first, then the fit.
  h.log.length = 0;
  h.store.update({ selected: null });
  h.mode.update();
  assert.deepEqual(h.log, ["restoreStartPick", "fitPrompt", "placeToast", "syncModelPick", "delivery off"]);
  assert.equal(h.els.history.children.length, 0, "the start page empties #history");
  assert.equal(h.els.empty.classList.contains("hidden"), false);
  assert.equal(h.els.button.textContent, "Start");
});

test("the apply: a running turn leaves the button's disabled as a send left it", () => {
  const h = harness();
  h.store.update({ selected: "s1", current: { owner: "worker" } });
  h.liveTurn.running = true;
  h.els.button.disabled = true;
  h.mode.update();
  assert.equal(h.els.button.disabled, true);
  assert.equal(h.els.button.textContent, "Send");
  assert.equal(h.els.prompt.placeholder, "Running… a message goes in at the next step · Enter to send · Alt+Enter queues");
  h.liveTurn.running = false;
  h.mode.update();
  assert.equal(h.els.button.disabled, false);
  h.store.update({ current: { owner: "tui" } });
  h.mode.update();
  assert.equal(h.els.button.disabled, true);
  assert.equal(h.els.attach.hidden, true);
});

test("a window crossing the phone's width redraws, and a grown one closes ⋯'s sheet", () => {
  const h = harness({ narrow: true });
  h.store.update({ selected: "s1", current: { owner: "worker" } });
  h.liveTurn.running = true;
  h.mode.update();
  assert.equal(h.els.prompt.placeholder, "Steer the turn…");
  h.media.matches = false;
  h.listeners.forEach((fn) => fn());
  assert.equal(h.els.prompt.placeholder.startsWith("Running…"), true);
  assert.equal(h.isSheetOpen(), false);
  h.media.matches = true;
  h.log.length = 0;
  h.listeners.forEach((fn) => fn());
  assert.equal(h.log.includes("closeSheet"), false);
});
