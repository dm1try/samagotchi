// The phone's ⋯ sheet (more_sheet.js): which rows a session has, ⋯'s dot, the
// actions' rules, and that an open sheet follows a redraw without losing its
// nodes (the clock ticks every second while a turn runs).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createMoreSheet, moreActions, moreAttention, moreRows } from "../../../lib/samagotchi/web/public/more_sheet.js";
import { infoButtons } from "../../../lib/samagotchi/web/public/info_bar_model.js";

const ID = "0123456789abcdef";
const bare = {
  id: ID, status: "idle", model: { text: "qwen", title: "qwen", mismatch: false },
  chain: { prev: null, next: null }, parent: null, kids: null, settings: null,
  toolkit: { summary: null, defaultKit: null }, notes: null, memories: [], workingSet: null, participants: null,
  dir: "/p", ctx: { text: "ctx 8%", tip: "t" }, speed: { text: "42 tok/s", tip: "s", empty: false }, clock: "1m 12s", worker: null,
};
const buttonsFor = ({ archived = false, continuing = false, next = null, owner = "worker", streaming = false } = {}) =>
  infoButtons({ id: ID, state: { owner }, chain: { next }, archived, continuing, streaming });

const keys = (bar) => moreRows(bar).map((r) => r.key);

test("a bare session has the model and toolkit rows alone; the others only when it has them", () => {
  assert.deepEqual(keys(bare), ["model", "toolkit"]);
  assert.deepEqual(keys(null), []);
  const full = {
    ...bare,
    memories: ["a"],
    participants: { text: "2 participants", count: 2, present: false },
    chain: { prev: { id: "p".repeat(16), date: "10:00" }, next: { id: "n".repeat(16), date: "" } },
    parent: { id: "f".repeat(16), title: "delegated by" },
    kids: { text: "⑂ 2", waitingText: null, title: "2 delegates" },
    notes: { text: "notes: gemma", title: "model notes in this session's prompt" },
    worker: { badge: { text: "chi 0.1", title: "older", restart: true }, busy: false },
  };
  assert.deepEqual(keys(full), ["model", "toolkit", "memories", "participants", "prev", "next", "parent", "delegates", "notes", "worker"]);
  const rows = moreRows(full);
  assert.equal(rows.find((r) => r.key === "prev").value, "← 10:00");
  assert.equal(rows.find((r) => r.key === "next").value, "nnnnnnnn →");
  assert.equal(rows.find((r) => r.key === "parent").value, "↑ ffffffff");
  assert.equal(rows.find((r) => r.key === "notes").value, "gemma");
});

test("the working set's row stands in the memories' place, as its chip does", () => {
  const on = { ...bare, memories: ["a"], workingSet: { chip: { n: 3, changed: false } } };
  assert.deepEqual(keys(on), ["model", "toolkit", "workingSet"]);
  const set = (bar) => moreRows(bar).find((r) => r.key === "workingSet").value;
  assert.equal(set(on), "3 items");
  assert.equal(set({ ...bare, workingSet: { chip: { n: 0, changed: false } } }), "empty");
  assert.equal(set({ ...bare, workingSet: { chip: { n: 1, changed: true } } }), "1 item, changed");
});

test("no invited participant yet is still a row: it is the way to Invite", () => {
  const rows = moreRows({ ...bare, participants: { text: "participants · invite", count: 0, present: false } });
  assert.equal(rows.find((r) => r.key === "participants").value, "Invite");
});

test("the toolkit row names the kit also on the default, where its chip is 🧰 alone", () => {
  const kit = (bar) => moreRows(bar).find((r) => r.key === "toolkit");
  assert.equal(kit(bare).value, "full");
  assert.equal(kit({ ...bare, toolkit: { summary: { name: "lean", label: "lean" }, defaultKit: "lean" } }).value, "lean");
  assert.match(kit(bare).info, /^Toolkit: full/);
});

test("⋯'s dot: nothing, the accent for a change, the warning for a delegate waiting or an older worker; its name says why", () => {
  assert.deepEqual(moreAttention(bare), { kind: null, label: "More" });
  assert.deepEqual(moreAttention(null), { kind: null, label: "More" });
  const changed = { ...bare, workingSet: { chip: { n: 3, changed: true } } };
  assert.deepEqual(moreAttention(changed), { kind: "accent", label: "More: Working set: 3 items, changed" });
  assert.equal(moreAttention({ ...bare, workingSet: { chip: { n: 3, changed: false } } }).kind, null);
  assert.equal(moreAttention({ ...bare, participants: { text: "1 participant", count: 1, present: true } }).kind, "accent");
  const waiting = { ...changed, kids: { text: "⑂ 2", waitingText: "1 waiting" } };
  assert.equal(moreAttention(waiting).kind, "warn");
  assert.match(moreAttention(waiting).label, /Delegates: ⑂ 2 · 1 waiting/);
  assert.equal(moreAttention({ ...bare, kids: { text: "⑂ 2", waitingText: null } }).kind, null);
  assert.equal(moreAttention({ ...bare, worker: { badge: { text: "chi 0.1", title: "t", restart: false }, busy: false } }).kind, "warn");
});

test("the actions follow the buttons' rules", () => {
  const shown = (o) => moreActions(buttonsFor(o)).map((a) => a.text);
  assert.deepEqual(shown(), ["Continue", "Archive", "Stop", "Delete"]);
  // Archived: no worker, Unarchive, and the accent on Continue.
  assert.deepEqual(shown({ archived: true, owner: null }), ["Continue", "Unarchive", "Delete"]);
  assert.equal(moreActions(buttonsFor({ archived: true, owner: null }))[0].accent, true);
  assert.equal(moreActions(buttonsFor())[0].accent, false);
  // Continued already, or a terminal's: no Continue, no Stop on a terminal's.
  assert.deepEqual(shown({ next: { id: "n" } }), ["Archive", "Stop", "Delete"]);
  assert.deepEqual(shown({ owner: "tui" }), ["Archive", "Delete"]);
  const busy = moreActions(buttonsFor({ continuing: true }))[0];
  assert.equal(busy.text, "Continuing…");
  assert.equal(busy.disabled, true);
});

function sheet() {
  const el = document.createElement("div");
  el.id = "infoBar";
  el.innerHTML = '<button id="infoMoreBtn">⋯</button><button id="infoContinueBtn"></button><button id="infoDeleteBtn"></button><div id="infoText"><button class="ws-chip"></button></div>';
  document.body.append(el);
  const button = el.querySelector("#infoMoreBtn");
  let sid = ID;
  const ctl = createMoreSheet({ el, button, session: () => sid, hash: (id) => `#/s/${id}`,
                                win: { innerWidth: 390, innerHeight: 800 } });
  return { ctl, el, button, setSession: (id) => { sid = id; }, done: () => { el.remove(); ctl.pop.remove(); } };
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("⋯ opens it as a bottom sheet; a redraw keeps it open, its nodes and focus, with the new numbers", () => {
  const { ctl, button, done } = sheet();
  ctl.update({ bar: { ...bare, workingSet: { chip: { n: 1, changed: false } } }, buttons: buttonsFor() });
  button.click();
  assert.equal(ctl.isOpen(), true);
  assert.ok(ctl.pop.classList.contains("sheet"));
  assert.equal(button.getAttribute("aria-expanded"), "true");
  const row = ctl.pop.querySelector('[data-act="go:workingSet"]');
  const clock = ctl.pop.querySelector(".more-clock");
  assert.equal(document.activeElement, ctl.pop.querySelector(".more-row"));
  row.focus();

  // A row that joins above keeps the focused one's node: each has its slot.
  ctl.update({ bar: { ...bare, workingSet: { chip: { n: 2, changed: true } }, clock: "1m 13s", kids: { text: "⑂ 1", waitingText: "1 waiting" } }, buttons: buttonsFor() });
  assert.equal(ctl.isOpen(), true);
  assert.equal(ctl.pop.querySelector('[data-act="go:workingSet"]'), row);
  assert.equal(document.activeElement, row);
  assert.equal(ctl.pop.querySelector(".more-clock"), clock);
  assert.equal(clock.textContent, "1m 13s");
  assert.match(row.textContent, /2 items, changed/);
  assert.equal(button.dataset.attention, "warn");
  done();
});

test("the sheet shows the telemetry line, with the clock's placeholder before a first turn", () => {
  const { ctl, button, done } = sheet();
  ctl.update({ bar: { ...bare, clock: "" }, buttons: buttonsFor() });
  button.click();
  assert.equal(ctl.pop.querySelector(".more-telemetry").textContent.replace(/\s+/g, " "), "ctx 8%42 tok/s–/p");
  done();
});

test("a row clicks its real chip, an action its real button, once the sheet has closed", async () => {
  const { ctl, el, button, done } = sheet();
  ctl.update({ bar: { ...bare, workingSet: { chip: { n: 1, changed: false } } }, buttons: buttonsFor() });
  const clicked = [];
  el.querySelector(".ws-chip").addEventListener("click", () => clicked.push(["ws", ctl.isOpen()]));
  el.querySelector("#infoDeleteBtn").addEventListener("click", () => clicked.push(["delete", ctl.isOpen()]));

  button.click();
  ctl.pop.querySelector('[data-act="go:workingSet"]').click();
  await tick();
  button.click();
  ctl.pop.querySelector('[data-act="go:delete"]').click();
  await tick();
  assert.deepEqual(clicked, [["ws", false], ["delete", false]]);
  done();
});

test("a tooltip-only chip's row unfolds its tooltip in place; a link is a link; another session closes the sheet", () => {
  const { ctl, button, setSession, done } = sheet();
  const bar = { ...bare, parent: { id: "f".repeat(16), title: "t" } };
  ctl.update({ bar, buttons: buttonsFor() });
  button.click();
  const toolkit = ctl.pop.querySelector('[data-act="info:toolkit"]');
  assert.equal(toolkit.getAttribute("aria-expanded"), "false");
  toolkit.click();
  assert.equal(ctl.isOpen(), true);
  assert.equal(toolkit.getAttribute("aria-expanded"), "true");
  assert.match(ctl.pop.querySelector(".more-info").textContent, /^Toolkit: full/);
  toolkit.click();
  assert.equal(ctl.pop.querySelector(".more-info"), null);
  assert.equal(ctl.pop.querySelector("a.more-row").getAttribute("href"), `#/s/${"f".repeat(16)}`);

  setSession("other");
  ctl.update({ bar, buttons: buttonsFor() });
  assert.equal(ctl.isOpen(), false);
  done();
});
