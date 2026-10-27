import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { markupOf } from "./dom_shim.js";
import { createUpdateSheet, updateSheetTemplate } from "../../../lib/samagotchi/web/public/update_sheet.js";

function dialog() {
  const el = document.createElement("dialog");
  el.showModal = () => { el.open = true; };
  el.close = () => { el.open = false; };
  document.body.appendChild(el);
  return el;
}

test("the install sheet shows component rows and calls out kept edits", () => {
  const div = document.createElement("div");
  div.innerHTML = markupOf(updateSheetTemplate({
    operation: "install", version: "99.0.0", state: "done",
    rows: [
      { component: "chi (gem)", status: "updated", from: "0.1.0", to: "99.0.0", kept: ["config.yml", "memories/notes.md"] },
      { component: "system bundle", status: "unchanged", kept: [] },
    ],
  }));
  const text = div.textContent.replace(/\s+/g, " ");

  assert.match(text, /Update chi to 99\.0\.0/);
  assert.deepEqual([...div.querySelectorAll(".us-row-head")].map((row) => [...row.children].map((part) => part.textContent)),
    [["chi (gem)", "updated"], ["system bundle", "unchanged"]]);
  assert.match(text, /0\.1\.0 → 99\.0\.0/);
  const kept = div.querySelector(".us-kept");
  assert.equal(kept.querySelector("strong").textContent, "Kept edited files:");
  assert.deepEqual([...kept.querySelectorAll("li")].map((file) => file.textContent), ["config.yml", "memories/notes.md"]);
});

test("the sheet follows update events and its operations call the owner APIs", async (t) => {
  const el = dialog();
  t.after(() => el.remove());
  const calls = [];
  const sheet = createUpdateSheet({
    dialog: el,
    update: async (version) => calls.push(["install", version]),
    restartWorkers: async () => calls.push(["workers"]),
    restartWeb: async () => calls.push(["web"]),
  });

  sheet.install("99.0.0");
  await Promise.resolve();
  assert.deepEqual(calls, [["install", "99.0.0"]]);
  assert.equal(sheet.isOpen(), true);
  assert.equal(sheet.receive({
    operation: "install", version: "99.0.0", state: "running", progress: "Installing samagotchi", rows: [],
  }), true);
  sheet.receive({
    operation: "install", version: "99.0.0", state: "done",
    rows: [{ component: "chi (gem)", status: "updated", kept: ["config.yml"] }],
  });
  assert.doesNotMatch(el.textContent, /Installing samagotchi/);
  assert.match(el.querySelector(".us-status").textContent, /Update complete\./);
  assert.deepEqual([...el.querySelectorAll(".us-kept li")].map((file) => file.textContent), ["config.yml"]);
  el.querySelector('[data-act="close"]').click();
  assert.equal(sheet.isOpen(), false);

  sheet.restartWorkers();
  await Promise.resolve();
  assert.deepEqual(calls.at(-1), ["workers"]);
  sheet.receive({
    operation: "workers", state: "done",
    rows: [{ session_id: "abcdef123456", state: "refused", reason: "fallback_held", holds: ["turn_running"] }],
  });
  assert.deepEqual([...el.querySelector(".us-row-head").children].map((part) => part.textContent),
    ["abcdef12", "refused"]);
  assert.match(el.textContent, /fallback_held/);
  assert.match(el.textContent, /turn running/);

  sheet.restartWeb();
  await Promise.resolve();
  assert.deepEqual(calls.at(-1), ["web"]);
  assert.match(el.textContent, /Waiting for chi web to reconnect/);
  assert.equal(sheet.reconnected("99.0.0"), true);
  assert.match(el.textContent, /Reconnected on chi 99\.0\.0/);
});

test("a failed request from a dismissed operation cannot replace the newer operation", async (t) => {
  const el = dialog();
  t.after(() => el.remove());
  let rejectInstall;
  const sheet = createUpdateSheet({
    dialog: el,
    update: () => new Promise((_resolve, reject) => { rejectInstall = reject; }),
    restartWorkers: async () => {},
    restartWeb: async () => {},
  });

  sheet.install("99.0.0");
  await Promise.resolve();
  sheet.restartWorkers();
  await Promise.resolve();
  rejectInstall(new Error("obsolete install failure"));
  await Promise.resolve();
  await Promise.resolve();

  assert.match(el.textContent, /Restart workers/);
  assert.doesNotMatch(el.textContent, /obsolete install failure/);
});

test("the status says the end of an operation, not its last progress line", () => {
  const status = (model) => {
    const div = document.createElement("div");
    div.innerHTML = markupOf(updateSheetTemplate(model));
    return div.querySelector(".us-status").textContent;
  };
  const progress = "installing samagotchi 99.0.0…";

  assert.equal(status({ operation: "install", state: "running", progress, rows: [] }), progress);
  assert.equal(status({ operation: "install", state: "done", progress, rows: [] }), "Update complete.");
  assert.equal(status({ operation: "install", state: "failed", progress, rows: [] }), "Operation failed.");
});

test("after an install, the sheet's footer offers both restarts, each showing its result there", async (t) => {
  const el = dialog();
  t.after(() => el.remove());
  const calls = [];
  const sheet = createUpdateSheet({
    dialog: el,
    update: async (version) => calls.push(["install", version]),
    restartWorkers: async () => calls.push(["workers"]),
    restartWeb: async () => calls.push(["web"]),
  });
  const actions = () => [...el.querySelectorAll(".us-foot [data-act^='restart']")].map((button) => button.textContent);

  sheet.install("99.0.0");
  sheet.receive({ operation: "install", version: "99.0.0", state: "running", rows: [] });
  assert.deepEqual(actions(), []);
  sheet.receive({ operation: "install", version: "99.0.0", state: "failed", rows: [] });
  assert.deepEqual(actions(), [], "a failed install offers no restart");
  sheet.receive({ operation: "install", version: "99.0.0", state: "done", rows: [] });
  assert.deepEqual(actions(), ["Restart workers", "Restart chi web"]);

  el.querySelector('[data-act="restart-workers"]').click();
  await Promise.resolve();
  assert.deepEqual(calls.at(-1), ["workers"]);
  assert.deepEqual(actions(), [], "none while it runs");
  sheet.receive({ operation: "workers", state: "done", rows: [{ session_id: "abcdef123456", state: "restarted", version: "99.0.0" }] });
  assert.match(el.textContent, /abcdef12/);
  assert.deepEqual(actions(), ["Restart workers", "Restart chi web"], "the other restart is still reachable");

  el.querySelector('[data-act="restart-web"]').click();
  await Promise.resolve();
  assert.deepEqual(calls.at(-1), ["web"]);
  assert.match(el.textContent, /Waiting for chi web to reconnect/);
  assert.deepEqual(actions(), []);
  sheet.reconnected("99.0.0");
  assert.match(el.textContent, /Reconnected on chi 99\.0\.0/);
  assert.deepEqual(actions(), ["Restart workers", "Restart chi web"]);
});

test("a restart from the installed notice's toast also offers the other one in the sheet", async (t) => {
  const el = dialog();
  t.after(() => el.remove());
  const sheet = createUpdateSheet({ dialog: el, update: async () => {}, restartWorkers: async () => {}, restartWeb: async () => {} });

  sheet.restartWeb();
  await Promise.resolve();
  sheet.reconnected("99.0.0");
  assert.ok(el.querySelector('[data-act="restart-workers"]'));
});
