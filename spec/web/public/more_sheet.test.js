// ⋯'s menu (more_sheet.js): which rows a session has, the folded ones only
// with a fold, ⋯'s dot and count, the telemetry line, the actions' rules, and
// that an open sheet follows a redraw without losing its nodes (the clock
// ticks every second while a turn runs).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { ACTION_KEYS, createMoreSheet, moreActions, moreAttention, moreCount, moreRows, moreTelemetry, ROW_KEYS } from "../../../lib/samagotchi/web/public/more_sheet.js";
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

test("the model's row unfolds only what its value doesn't already say", () => {
  const model = (text, title) => moreRows({ ...bare, model: { text, title, mismatch: false } })[0];
  assert.equal(model("qwen", "qwen").info, null);
  assert.equal(model("qwen", "served: gemma; asked for qwen").info, "served: gemma; asked for qwen");
});

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

// The sheet's order is BAR_ITEMS' menuOrder: today's rows, with the three a
// fold adds (id, ⚙, earlier links pruned) in their places.
test("the rows' and the actions' order, from BAR_ITEMS", () => {
  assert.deepEqual(ROW_KEYS, ["id", "model", "settings", "toolkit", "workingSet", "memories", "participants", "pruned", "prev", "next", "parent", "delegates", "notes", "worker"]);
  assert.deepEqual(ROW_KEYS.filter((k) => !["id", "settings", "pruned"].includes(k)),
                   ["model", "toolkit", "workingSet", "memories", "participants", "prev", "next", "parent", "delegates", "notes", "worker"]);
  assert.deepEqual(ACTION_KEYS, ["continue", "archive", "stop", "delete"]);
});

const settings = { thinking: { level: "low", source: "session", own: "low" }, reasoningHistory: null, llmContext: null };

test("without a fold the id, ⚙ and pruned rows don't show; with one, only the folded rows do", () => {
  const bar = { ...bare, settings, chain: { prev: null, next: null, pruned: true }, notes: { text: "notes: gemma", title: "t" } };
  assert.deepEqual(keys(bar), ["model", "toolkit", "notes"]);
  const folded = (...names) => moreRows(bar, new Set(names)).map((r) => r.key);
  assert.deepEqual(folded(), []);
  assert.deepEqual(folded("notes", "id", "settings", "pruned", "dir"), ["id", "settings", "pruned", "notes"]);
  const rows = moreRows(bar, new Set(["id", "settings", "pruned"]));
  assert.deepEqual(rows.map((r) => [r.label, r.value, r.go]), [
    ["Session id", "01234567", "id"], ["Settings", "think low", "settings"], ["Earlier links pruned", "by a schedule", undefined]]);
  // A ← link there is no pruned row (the bar draws the link instead).
  assert.deepEqual(moreRows({ ...bar, chain: { prev: { id: "p".repeat(16), date: "" }, next: null, pruned: true } }, new Set(["pruned", "prev"])).map((r) => r.key), ["prev"]);
});

test("with a fold, Continue and Stop only when folded; Archive and Delete always; the dot from folded rows alone", () => {
  const shown = (folded) => moreActions(buttonsFor(), folded).map((a) => a.key);
  assert.deepEqual(shown(new Set()), ["archive", "delete"]);
  assert.deepEqual(shown(new Set(["continue", "stop"])), ["continue", "archive", "stop", "delete"]);
  const waiting = { ...bare, kids: { text: "⑂ 2", waitingText: "1 waiting" } };
  assert.equal(moreAttention(waiting, new Set()).kind, null);
  assert.equal(moreAttention(waiting, new Set(["delegates"])).kind, "warn");
});

function sheet() {
  const el = document.createElement("div");
  el.id = "infoBar";
  el.innerHTML = '<button id="infoMoreBtn">⋯<span class="more-count"></span></button><button id="infoContinueBtn"></button><button id="infoDeleteBtn"></button><div id="infoText"><button class="ws-chip"></button></div>';
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
  assert.ok(ctl.pop.querySelector('[data-act="info:model"]') === null, "a model row with nothing more to say doesn't unfold");
  const toolkit = ctl.pop.querySelector('[data-act="info:toolkit"]');
  assert.equal(toolkit.getAttribute("aria-expanded"), "false");
  toolkit.click();
  assert.equal(ctl.isOpen(), true);
  assert.equal(toolkit.getAttribute("aria-expanded"), "true");
  assert.match(ctl.pop.querySelector(".more-info").textContent, /^Toolkit: full/);
  toolkit.click();
  assert.ok(ctl.pop.querySelector(".more-info") === null);
  assert.equal(ctl.pop.querySelector("a.more-row").getAttribute("href"), `#/s/${"f".repeat(16)}`);

  setSession("other");
  ctl.update({ bar, buttons: buttonsFor() });
  assert.equal(ctl.isOpen(), false);
  done();
});

test("the telemetry line: all of it without a fold; with one only the folded speed, clock and folder, none when none", () => {
  assert.deepEqual(moreTelemetry(bare), ["ctx", "speed", "time", "dir"]);
  assert.deepEqual(moreTelemetry({ ...bare, speed: null }), ["ctx", "time", "dir"]);
  assert.deepEqual(moreTelemetry(bare, new Set(["ctx", "time", "dir", "notes"])), ["time", "dir"]);
  assert.deepEqual(moreTelemetry(bare, new Set(["notes"])), []);
  const { ctl, button, done } = sheet();
  ctl.update({ bar: bare, buttons: buttonsFor(), folded: new Set(["time", "dir"]) });
  button.click();
  assert.equal(ctl.pop.querySelector(".more-telemetry").textContent.replace(/\s+/g, " "), "1m 12s/p");
  assert.ok(ctl.pop.querySelector(".more-ctx") === null, "ctx is on the row");
  ctl.update({ bar: bare, buttons: buttonsFor(), folded: new Set(["notes"]) });
  assert.ok(ctl.pop.querySelector(".more-telemetry") === null);
  done();
});

test("⋯'s count: the folded rows, telemetry and actions; Archive and Delete never count; none at 0", () => {
  const bar = { ...bare, settings, notes: { text: "notes: gemma", title: "t" } };
  assert.equal(moreCount(bar, buttonsFor(), null), 0);
  assert.equal(moreCount(bar, buttonsFor(), new Set(["archive", "delete"])), 0);
  // notes, toolkit (rows), dir (telemetry), continue (an action); a compact ⚙ isn't folded.
  assert.equal(moreCount(bar, buttonsFor(), new Set(["notes", "toolkit", "dir", "continue", "archive", "delete"])), 4);
  // A folded key the session hasn't (no participants chip) doesn't count.
  assert.equal(moreCount(bar, buttonsFor(), new Set(["participants"])), 0);
  const { ctl, button, done } = sheet();
  ctl.update({ bar, buttons: buttonsFor(), folded: new Set(["notes", "toolkit", "archive", "delete"]) });
  assert.equal(button.querySelector(".more-count").textContent, "2");
  assert.equal(button.getAttribute("aria-label"), "More (2 folded)");
  ctl.update({ bar, buttons: buttonsFor(), folded: new Set(["archive", "delete"]) });
  assert.equal(button.querySelector(".more-count").textContent, "");
  assert.equal(button.getAttribute("aria-label"), "More");
  done();
});

test("the ⚙ row says the session's own values, or that it follows the model", () => {
  const follows = { thinking: { level: "high", source: "models: qwen", own: null }, reasoningHistory: null, llmContext: null };
  const row = (s) => moreRows({ ...bare, settings: s }, new Set(["settings"]))[0];
  assert.deepEqual([row(settings).label, row(settings).value], ["Settings", "think low"]);
  assert.equal(row(follows).value, "follows the model");
});
