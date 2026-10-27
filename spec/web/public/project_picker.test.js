import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createProjectPicker, pickerTemplate } from "../../../lib/samagotchi/web/public/project_picker.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

const current = {
  name: "samagotchi", root: "/home/me/samagotchi", root_label: "~/samagotchi",
  dir: "/home/me/samagotchi/lib", sessions: 2, waiting: 1, updated_at: "2026-10-27T12:00:00Z",
  default: true, current: true,
};
const other = {
  name: "coffee_assistant", root: "/work/coffee_assistant", root_label: "/work/coffee_assistant",
  dir: "/work/coffee_assistant", sessions: 3, waiting: 0, updated_at: "2026-10-26T12:00:00Z",
  default: false, current: false,
};

test("the project picker preserves row order and marks current/default rows with view-only links", () => {
  const host = document.createElement("div");
  render(pickerTemplate({
    rows: [current, other], search: "?dir=/ignored&view=turn", currentDir: current.dir,
  }), host);
  const rows = [...host.querySelectorAll(".project-row:not(.project-all)")];

  assert.deepEqual(rows.map((row) => row.querySelector(".project-name").textContent), ["samagotchi", "coffee_assistant"]);
  assert.equal(rows[0].getAttribute("href"), "/?view=turn");
  assert.equal(rows[0].getAttribute("aria-current"), "page");
  assert.match(rows[0].textContent, /default/);
  assert.match(rows[0].textContent, /1 waiting/);
  assert.match(rows[0].textContent, /2 sessions/);
  assert.match(rows[0].textContent, /~\/samagotchi/);
  assert.equal(rows[1].getAttribute("href"), "/?dir=/work/coffee_assistant&view=turn");
  assert.equal(rows[1].getAttribute("aria-current"), null);
  assert.match(rows[1].textContent, /3 sessions/);
  assert.equal(host.querySelector("#projectAll").getAttribute("href"),
    "/?scope=all&from=/home/me/samagotchi/lib&view=turn");
  // The all row's caption is a label, not a path: no .project-root (the monospace path style).
  assert.equal(host.querySelector("#projectAll .project-root"), null);
  assert.equal(host.querySelector("#projectAll .project-hint").textContent, "Every session");
});

test("the All projects row is current in the all view and has no hash", () => {
  const host = document.createElement("div");
  render(pickerTemplate({ rows: [other], search: "?view=stage", allCurrent: true }), host);

  const all = host.querySelector("#projectAll");
  assert.equal(all.getAttribute("href"), "/?scope=all&view=stage");
  assert.equal(all.getAttribute("aria-current"), "page");
});

function openPicker({ scope = { dir: "/home/me/samagotchi/lib" }, api = async () => [current, other],
                      scopeError = () => null, search = "?view=turn", width = 1000 } = {}) {
  const el = document.createElement("div");
  el.innerHTML = '<button id="scopePick" type="button">scope</button>';
  document.body.append(el);
  const picker = createProjectPicker({
    el, scope, scopeError, api, where: () => ({ search }), doc: document,
    win: { innerWidth: width, innerHeight: 800 },
  });
  return { el, picker, button: el.querySelector("#scopePick"), done: () => { picker.pop.remove(); el.remove(); } };
}

test("opening fetches the scoped list, shows loading first, focuses the current row and uses a phone sheet", async () => {
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  const calls = [];
  const s = openPicker({ api: (path) => { calls.push(path); return pending; }, width: 390 });
  s.button.click();
  assert.equal(s.picker.pop.classList.contains("sheet"), true);
  assert.match(s.picker.pop.textContent, /Loading projects/);
  assert.deepEqual(calls, ["/api/projects?dir=%2Fhome%2Fme%2Fsamagotchi%2Flib"]);

  resolve([current, other]);
  await Promise.resolve();
  assert.equal(s.picker.pop.querySelectorAll(".project-row:not(.project-all)").length, 2);
  assert.equal(document.activeElement, s.picker.pop.querySelector('[aria-current="page"]'));
  s.done();
});

test("a failed request shows one error line and keeps the All projects escape row", async () => {
  const s = openPicker({ api: async () => { throw new Error("offline"); }, scopeError: () => "bad folder" });
  s.button.click();
  await Promise.resolve();

  assert.equal(s.picker.pop.querySelectorAll('[role="alert"]').length, 1);
  assert.match(s.picker.pop.querySelector('[role="alert"]').textContent, /Can't read projects: offline/);
  assert.equal(s.picker.pop.querySelectorAll(".project-row:not(.project-all)").length, 0);
  assert.equal(s.picker.pop.querySelector("#projectAll").getAttribute("href"), "/?scope=all&view=turn");
  s.done();
});

test("the folder-not-found chip asks without the dead folder and lists the projects to leave it", async () => {
  const asked = [];
  const row = { name: "alpha", root: "/r/alpha", root_label: "~/alpha", dir: "/r/alpha", sessions: 1, waiting: 0,
    updated_at: "2026-10-27T00:00:00Z", default: true, current: false };
  const s = openPicker({ api: async (url) => { asked.push(url); return [row]; }, scopeError: () => "bad folder" });
  s.button.click();
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(asked, ["/api/projects"]);
  assert.equal(s.picker.pop.querySelectorAll(".project-row:not(.project-all)").length, 1);
  s.done();
});

test("a late response from an earlier open cannot replace the latest project list", async () => {
  const requests = [];
  const s = openPicker({ api: () => new Promise((resolve) => requests.push(resolve)) });
  s.button.click();
  s.button.click();
  s.button.click();
  assert.equal(requests.length, 2);

  requests[1]([other]);
  await Promise.resolve();
  requests[0]([current]);
  await Promise.resolve();
  assert.equal(s.picker.pop.querySelector(".project-name").textContent, "coffee_assistant");
  s.done();
});
