// A mixed cache around the drafts (docs/internals/web-frontend.md, New
// exports go in new modules): a proxy that ignores no-cache may serve
// 0.191.0's send_turn.js beside this app.js. Loaded from a copy of the
// page's modules with the old file put back (fixtures/v0.191.0/, the
// released file), it gets the composer bag this app.js passes (its el,
// setChips and key-less calls kept for it) over real drafts (drafts.js): the
// line still goes, and the ack empties the box. The other way round (this
// send_turn.js, an older app.js's bag) is send_turn.test.js'. Goes at the
// next release, with the bag's old members.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createDrafts } from "../../../lib/samagotchi/web/public/drafts.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

const here = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(here, "../../../lib/samagotchi/web/public");
const OLD = join(here, "fixtures/v0.191.0");
if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;

// The page's modules with +oldFiles+ as 0.191.0 shipped them.
async function mixed(oldFiles, file) {
  const dir = mkdtempSync(join(tmpdir(), "chi-mixed-drafts-"));
  test.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(PUBLIC, dir, { recursive: true });
  for (const old of oldFiles) cpSync(join(OLD, old), join(dir, old));
  return import(pathToFileURL(join(dir, file)).href);
}

const { createSendTurn: oldSendTurn } = await mixed(["send_turn.js"], "send_turn.js");

// The page as app.js wires it: the drafts over a textarea and a stand-in
// mount, the composer bag as app.js passes it to createSendTurn.
function page({ open = "s1", text = "hello" } = {}) {
  const promptEl = document.createElement("textarea");
  document.body.append(promptEl);
  let list = [];
  const mount = { chips: () => list, setChips: (next) => { list = next; } };
  const world = { selected: open };
  const shownDraft = () => world.selected ?? "";
  const drafts = createDrafts({ promptEl, view: mount, shownKey: shownDraft });
  drafts.show(shownDraft());
  drafts.setText(shownDraft(), text);
  const calls = [];
  const store = createSessionStore({ initial: { owner: "worker", commands: [], firstPreview: "first" } });
  const send = oldSendTurn({
    session: () => world.selected, store, running: () => false, clientId: "web:t1", sentIds: new Set(), earlyRestores: new Map(),
    api: {
      createIdleSession: async () => ({ id: "new1" }),
      uploadImage: async (id, _file, name) => { calls.push(["upload", id, name]); return { file: name }; },
      sendTurn: async (...args) => { calls.push(["turn", ...args]); return { enqueued_id: "e1" }; },
    },
    dir: null,
    startPage: { pendingPick: () => null, chosenModel: () => null, newChoices: () => ({}), clearChoices: () => {} },
    takeDelivery: () => null,
    // app.js's bag, as it is.
    composer: {
      text: (key) => drafts.text(key), setText: (key, value) => drafts.setText(key, value),
      putChips: (key, chips) => drafts.putChips(key, chips), move: (from, to) => drafts.move(from, to),
      el: promptEl,
      button: { disabled: false },
      chips: (key) => drafts.chips(key ?? shownDraft()),
      setChips: (chips) => drafts.putChips(shownDraft(), chips),
      fit: () => {},
      clear: (key) => drafts.clear(key ?? shownDraft()),
      openForVisit: () => {},
      focus: () => {},
      noteDraft: () => drafts.syncFromView(),
    },
    historyEl: document.createElement("div"),
    turnDom: { handOff: () => {}, holds: () => false },
    makeUserBubble: () => document.createElement("div"),
    bubbleById: () => null,
    addCommandBubble: () => {},
    addCreatedSession: () => {},
    // app.js's: the start page's draft goes with the session made from it
    // (an older send_turn.js doesn't move it), then select's forgetSession swaps.
    select: async (id) => {
      if (!world.selected) drafts.move("", id);
      world.selected = id;
      drafts.show(id);
    },
    showNotice: () => {},
    followWokenWorker: () => {},
    refreshHistory: () => {},
    leaveGoneSession: () => {},
    runCommand: null,
    toast: () => {},
  }).send;
  return { send, promptEl, drafts, mount, calls, world };
}

test("0.191.0's send_turn.js beside this app.js: the line goes, the ack empties the box, the sent chips go", async () => {
  const p = page();
  p.mount.setChips([{ name: "a.png", file: {} }]);
  await p.send();
  assert.deepEqual(p.calls.map((c) => c.slice(0, 3)), [["upload", "s1", "a.png"], ["turn", "s1", "hello"]]);
  assert.equal(p.promptEl.value, "");
  assert.equal(p.drafts.text("s1"), "");
  assert.deepEqual(p.drafts.chips("s1"), []);
});

test("0.191.0's send_turn.js beside this app.js: the start page's line makes the session and goes", async () => {
  const p = page({ open: null, text: "start here" });
  await p.send();
  assert.deepEqual(p.calls.map((c) => c.slice(0, 3)), [["turn", "new1", "start here"]]);
  assert.equal(p.world.selected, "new1");
  assert.equal(p.promptEl.value, "");
  assert.equal(p.drafts.text(""), "", "the start page's draft went with the session, not left to be sent again");
  assert.ok(localStorage.getItem("chi_start_draft") === null);
});
