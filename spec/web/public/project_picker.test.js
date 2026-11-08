import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createProjectPicker, pickerTemplate } from "../../../lib/samagotchi/web/public/project_picker.js";
import { projectScopeHref } from "../../../lib/samagotchi/web/public/scope.js";
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

test("the project picker preserves row order and marks current/default rows with plain links", () => {
  const host = document.createElement("div");
  render(pickerTemplate({
    rows: [current, other], currentDir: current.dir,
  }), host);
  const rows = [...host.querySelectorAll("a.project-row:not(.project-all)")];

  assert.deepEqual(rows.map((row) => row.querySelector(".project-name").textContent), ["samagotchi", "coffee_assistant"]);
  assert.equal(rows[0].getAttribute("href"), "/");
  assert.equal(rows[0].getAttribute("aria-current"), "page");
  assert.match(rows[0].textContent, /default/);
  assert.match(rows[0].textContent, /1 waiting/);
  assert.match(rows[0].textContent, /2 sessions/);
  assert.match(rows[0].textContent, /~\/samagotchi/);
  assert.equal(rows[1].getAttribute("href"), "/?dir=/work/coffee_assistant");
  assert.equal(rows[1].getAttribute("aria-current"), null);
  assert.match(rows[1].textContent, /3 sessions/);
  assert.equal(host.querySelector("#projectAll").getAttribute("href"),
    "/?scope=all&from=/home/me/samagotchi/lib");
  // The all row's caption is a label, not a path: no .project-root (the monospace path style).
  assert.ok(host.querySelector("#projectAll .project-root") === null);
  assert.equal(host.querySelector("#projectAll .project-hint").textContent, "Every session");
  assert.ok(host.querySelector("#projectAll").compareDocumentPosition(host.querySelector('[data-act="new-project"]')) &
    Node.DOCUMENT_POSITION_FOLLOWING);
});

test("the All projects row is current in the all view and has no hash", () => {
  const host = document.createElement("div");
  render(pickerTemplate({ rows: [other], allCurrent: true }), host);

  const all = host.querySelector("#projectAll");
  assert.equal(all.getAttribute("href"), "/?scope=all");
  assert.equal(all.getAttribute("aria-current"), "page");
});

function openPicker({ scope = { dir: "/home/me/samagotchi/lib" }, api = async () => [current, other],
                      scopeError = () => null, width = 1000 } = {}) {
  const el = document.createElement("div");
  el.innerHTML = '<button id="scopePick" type="button">scope</button>';
  document.body.append(el);
  const assigned = [];
  const win = { innerWidth: width, innerHeight: 800, location: { assign: (href) => assigned.push(href) } };
  const picker = createProjectPicker({
    el, scope, scopeError, api, doc: document,
    win,
  });
  return { el, picker, button: el.querySelector("#scopePick"), assigned,
    done: () => { picker.pop.remove(); el.remove(); } };
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
  assert.equal(s.picker.pop.querySelectorAll("a.project-row:not(.project-all)").length, 2);
  assert.equal(document.activeElement, s.picker.pop.querySelector('[aria-current="page"]'));
  s.done();
});

test("a failed request shows one error line and keeps the All projects escape row", async () => {
  const s = openPicker({ api: async () => { throw new Error("offline"); }, scopeError: () => "bad folder" });
  s.button.click();
  await Promise.resolve();

  assert.equal(s.picker.pop.querySelectorAll('[role="alert"]').length, 1);
  assert.match(s.picker.pop.querySelector('[role="alert"]').textContent, /Can't read projects: offline/);
  assert.equal(s.picker.pop.querySelectorAll("a.project-row:not(.project-all)").length, 0);
  assert.equal(s.picker.pop.querySelector("#projectAll").getAttribute("href"), "/?scope=all");
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
  assert.equal(s.picker.pop.querySelectorAll("a.project-row:not(.project-all)").length, 1);
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

test("New project opens with the default root's parent and places the caret at the end", async () => {
  const row = { ...current, root_label: "~/projects/samagotchi" };
  const s = openPicker({ api: async () => [row] });
  s.button.click();
  await Promise.resolve();
  s.picker.pop.querySelector('[data-act="new-project"]').click();

  const input = s.picker.pop.querySelector('[name="dir"]');
  assert.equal(input.value, "~/projects/");
  assert.equal(input.selectionStart, input.value.length);
  assert.equal(input.selectionEnd, input.value.length);
  s.done();
});

test("typed project path survives a project-list redraw", async () => {
  const s = openPicker();
  s.button.click();
  await Promise.resolve();
  s.picker.pop.querySelector('[data-act="new-project"]').click();
  const input = s.picker.pop.querySelector('[name="dir"]');
  input.value = "~/projects/notes";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));

  s.picker.load();

  assert.equal(s.picker.pop.querySelector('[name="dir"]').value, "~/projects/notes");
  await Promise.resolve();
  s.done();
});

test("creating a project navigates to its project scope without a hash", async () => {
  const calls = [];
  const dir = "/home/me/projects/notes";
  const s = openPicker({ api: async (path, opts) => {
    calls.push([path, opts]);
    return opts?.method === "POST" ? { outcome: "created", root: dir, dir } : [current, other];
  } });
  s.button.click();
  await Promise.resolve();
  s.picker.pop.querySelector('[data-act="new-project"]').click();
  const input = s.picker.pop.querySelector('[name="dir"]');
  input.value = dir;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  s.picker.pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await Promise.resolve();

  assert.deepEqual(calls.at(-1), ["/api/projects", { method: "POST", body: JSON.stringify({ dir }) }]);
  assert.deepEqual(s.assigned, [projectScopeHref(dir, "")]);
  s.done();
});

test("a create refusal shows the server detail and keeps the entered path", async () => {
  const s = openPicker({ api: async (path, opts) => {
    if (opts?.method === "POST") throw { body: { detail: "home cannot be a project" }, message: "above_home" };
    return [current, other];
  } });
  s.button.click();
  await Promise.resolve();
  s.picker.pop.querySelector('[data-act="new-project"]').click();
  const input = s.picker.pop.querySelector('[name="dir"]');
  input.value = "/home/me";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  s.picker.pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await Promise.resolve();

  assert.equal(s.picker.pop.querySelector('[name="dir"]').value, "/home/me");
  assert.equal(s.picker.pop.querySelector('[role="alert"]').textContent, "home cannot be a project");
  s.done();
});

test("Cancel restores the New project row", async () => {
  const s = openPicker();
  s.button.click();
  await Promise.resolve();
  s.picker.pop.querySelector('[data-act="new-project"]').click();
  assert.ok(s.picker.pop.querySelector('[name="dir"]'));
  s.picker.pop.querySelector('[data-act="cancel-new"]').click();

  assert.ok(s.picker.pop.querySelector('[name="dir"]') === null);
  assert.ok(s.picker.pop.querySelector('[data-act="new-project"]'));
  s.done();
});

test("a create response after the picker closes is dropped", async () => {
  let resolve;
  const pending = new Promise((done) => { resolve = done; });
  const s = openPicker({ api: async (path, opts) => (opts?.method === "POST" ? pending : [current, other]) });
  s.button.click();
  await Promise.resolve();
  s.picker.pop.querySelector('[data-act="new-project"]').click();
  s.picker.pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  s.picker.pop.querySelector('[data-act="close"]').click();
  resolve({ outcome: "created", root: "/new", dir: "/new" });
  await Promise.resolve();

  assert.deepEqual(s.assigned, []);
  assert.equal(s.picker.isOpen(), false);
  s.done();
});
