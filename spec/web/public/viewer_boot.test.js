// The main page booted whole with a viewer stamped on <body> (page_boot.js,
// in its own process): with every capability it makes today's calls and
// draws today's controls; with none it makes no call to an owner route
// (App::ROUTES :owner) and draws no owner control. docs/internals/
// web-frontend.md (The viewer) has the table of what gates what.
import test from "node:test";
import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const BOOT = fileURLToPath(new URL("./page_boot.js", import.meta.url));
const SID = "11111111-1111-4111-8111-111111111111";
// Web::Viewer::CAPABILITIES (spec/web/viewer_spec.rb pins the server's list).
const ALL = ["sessions", "models", "prompt_history", "push", "context", "working_set", "working_set_items", "participants_admin", "rename", "images",
  "session_controls", "revise", "apply", "answer_cards", "render", "block_renderers", "stop_any_turn", "steer_any_turn"];

function boot(viewer) {
  const out = execFileSync(process.execPath, [BOOT, JSON.stringify(viewer)], { encoding: "utf8", timeout: 60_000 });
  const result = JSON.parse(out.trim().split("\n").at(-1));
  assert.deepEqual(result.errors, [], "the page booted without an error");
  return result;
}

test("every capability: today's calls and controls", () => {
  const { requests, streams, controls } = boot({ kind: "owner", can: ALL });
  assert.deepEqual(requests, [
    "GET /api/block_renderers",
    "GET /api/history",
    "GET /api/models",
    `GET /api/sessions/${SID}`,
    `GET /api/sessions/${SID}/context`,
    `GET /api/sessions/${SID}/participants`,
    `GET /api/sessions/${SID}/working_set`,
    "POST /api/push/presence",
    "POST /api/render",
  ]);
  assert.deepEqual(streams, ["/api/events", `/api/sessions/${SID}/stream`]);
  assert.deepEqual(controls, {
    newBtn: "shown", scope: "shown", topStrip: "shown", stripStatus: "shown", stripGrip: "shown",
    // No Notification API here: the bell stays hidden; the model list is empty: no picker.
    notifyBtn: "hidden", titleRenameBtn: "shown", modelPick: "hidden", attachBtn: "shown",
    infoMoreBtn: "shown", infoStopBtn: "shown", infoContinueBtn: "shown", infoArchiveBtn: "shown", infoDeleteBtn: "shown",
    stopTurn: "shown", questionCard: "shown", applyRow: "shown", reviseBtn: "shown", settingsChip: "shown",
  });
});

test("no capability: no owner route is called and no owner control is drawn", () => {
  const { requests, streams, controls } = boot({ kind: "participant", can: [] });
  // The show and its stream are a participant's routes; nothing else goes out.
  assert.deepEqual(requests, [`GET /api/sessions/${SID}`]);
  assert.deepEqual(streams, [`/api/sessions/${SID}/stream`]);
  for (const [name, state] of Object.entries(controls)) assert.notEqual(state, "shown", `${name} is drawn`);
  // Drawn per turn: none made (the stage's Stop turn is its row's, kept hidden with no onCancel).
  for (const name of ["questionCard", "applyRow", "reviseBtn", "settingsChip"]) assert.equal(controls[name], "absent", `${name} exists`);
});

test("a participant: their show and the working set, their stream; no owner control, and no Stop turn on the owner's running turn", () => {
  const { requests, streams, controls } = boot({ kind: "participant", can: ["send", "stop_own_turn", "steer_own_turn", "working_set"] });
  assert.deepEqual(requests, [`GET /api/sessions/${SID}`, `GET /api/sessions/${SID}/working_set`]);
  assert.deepEqual(streams, [`/api/sessions/${SID}/stream`]);
  for (const [name, state] of Object.entries(controls)) assert.notEqual(state, "shown", `${name} is drawn`);
});

// What each capability gates on this page (docs/internals/web-frontend.md,
// The viewer): without it alone, those calls and controls go, and the rest
// of today's page stays.
const GATES = {
  sessions: { requests: [], streams: ["/api/events"], controls: ["newBtn", "scope", "topStrip", "stripStatus", "stripGrip"] },
  models: { requests: ["GET /api/models"] },
  prompt_history: { requests: ["GET /api/history"] },
  push: { requests: ["POST /api/push/presence"] },
  context: { requests: [`GET /api/sessions/${SID}/context`] },
  working_set: { requests: [`GET /api/sessions/${SID}/working_set`] },
  participants_admin: { requests: [`GET /api/sessions/${SID}/participants`] },
  render: { requests: ["POST /api/render"] },
  block_renderers: { requests: ["GET /api/block_renderers"] },
  rename: { controls: ["titleRenameBtn"] },
  images: { controls: ["attachBtn"] },
  session_controls: { controls: ["infoMoreBtn", "infoStopBtn", "infoContinueBtn", "infoArchiveBtn", "infoDeleteBtn", "settingsChip"] },
  stop_any_turn: { controls: ["stopTurn"] },
  answer_cards: { controls: ["questionCard"] },
  apply: { controls: ["applyRow"] },
  revise: { controls: ["reviseBtn"] },
};

test("each capability gates its own calls and controls, and nothing else", async () => {
  const run = promisify(execFile);
  const full = boot({ kind: "owner", can: ALL });
  const names = Object.keys(GATES);
  const outs = await Promise.all(names.map((name) => run(process.execPath,
    [BOOT, JSON.stringify({ kind: "owner", can: ALL.filter((n) => n !== name) })], { encoding: "utf8", timeout: 60_000 })));
  outs.forEach(({ stdout }, i) => {
    const name = names[i];
    const gate = GATES[name];
    const got = JSON.parse(stdout.trim().split("\n").at(-1));
    assert.deepEqual(got.errors, [], `${name}: booted without an error`);
    assert.deepEqual(got.requests, full.requests.filter((r) => !(gate.requests || []).includes(r)), `${name}: its calls only`);
    assert.deepEqual(got.streams, full.streams.filter((r) => !(gate.streams || []).includes(r)), `${name}: its streams only`);
    for (const [control, state] of Object.entries(full.controls)) {
      const want = (gate.controls || []).includes(control) ? (state === "shown" ? "not shown" : state) : state;
      if (want === "not shown") assert.notEqual(got.controls[control], "shown", `${name}: ${control} drawn`);
      else assert.equal(got.controls[control], want, `${name}: ${control} changed`);
    }
  });
});
