// The Stop button's sheet (stop_sheet.js): what the worker's holds become in
// the sheet, and what its three answers do. The words come from the worker's
// own StoppableHold JSON (WorkerIdleExit#stoppable_holds).
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createStopSheet, MAX_NAMED, stopSheetModel, stopSheetTemplate } from
  "../../../lib/samagotchi/web/public/stop_sheet.js";

const task = (id, command, age) => ({ id, label: command, detail: age });
const holds = () => [
  { kind: "background_tasks", items: [task("20261026120000-abcdef12", "npm test", "3m")] },
  { kind: "delegates", items: [{ id: "ab12cd34-5678", label: "fix the grip", detail: "running a turn" }] },
];

test("nothing stoppable is no sheet: empty, null, a hold with no items", () => {
  assert.equal(stopSheetModel([]), null);
  assert.equal(stopSheetModel(null), null);
  assert.equal(stopSheetModel(undefined), null);
  assert.equal(stopSheetModel([{ kind: "reminders", items: [] }]), null);
  assert.equal(stopSheetModel({ holds: [] }), null);
});

test("the sheet says one line per kind, with its count, its items and its detail", () => {
  const model = stopSheetModel(holds());

  assert.equal(model.total, 2);
  assert.deepEqual(model.lines.map((line) => [line.kind, line.count, line.word]),
                   [["background_tasks", 1, "background task"], ["delegates", 1, "delegate"]]);
  assert.deepEqual(model.lines[0].items, ["npm test (3m)"]);
  assert.deepEqual(model.lines[1].items, ['ab12cd34 "fix the grip" running a turn']);
  assert.equal(model.lines[0].more, 0);
  assert.equal(model.lines[1].note, "");
});

test("reminders are listed with their schedule and the note that they end with the session", () => {
  const model = stopSheetModel([
    { kind: "reminders", items: [
      { id: "api_health", label: "api_health", detail: "every 20m" },
      { id: "stretch", label: "stretch", detail: "every 5m, due now" },
    ] },
  ]);

  assert.equal(model.lines[0].word, "reminders");
  assert.deepEqual(model.lines[0].items, ["api_health (every 20m)", "stretch (every 5m, due now)"]);
  assert.match(model.lines[0].note, /end with the session/);
});

test("at most three of a kind named, the rest one +N more; a long command cut short", () => {
  const items = Array.from({ length: MAX_NAMED + 2 }, (_, i) => task(`t${i}`, `sleep ${i}`, "1m"));
  const model = stopSheetModel([{ kind: "background_tasks", items }]);

  assert.equal(model.lines[0].count, 5);
  assert.equal(model.lines[0].items.length, MAX_NAMED);
  assert.equal(model.lines[0].more, 2);

  const long = stopSheetModel([{ kind: "background_tasks",
                                items: [task("t1", "bundle exec rspec spec lib/samagotchi/bundles/*/spec", "2m")] }]);
  const cut = long.lines[0].items[0];
  assert.ok(cut.startsWith("bundle exec rspec spec lib/samagotchi/bund…"), cut);
  assert.ok(cut.endsWith(" (2m)"), cut);

  const total = stopSheetModel([{ kind: "reminders", items: [{ id: "a", label: "a" }] },
                                { kind: "delegates", items: [{ id: "b", label: "b", detail: "a live worker" }] }]);
  assert.equal(total.total, 2);
});

test("the sheet's three answers: Stop all, Stop session only, Cancel", () => {
  const markup = markupOf(stopSheetTemplate(stopSheetModel(holds())));
  const div = document.createElement("div");
  div.innerHTML = markup;

  assert.deepEqual([...div.querySelectorAll(".ss-acts button")].map((b) => [b.dataset.act, b.textContent]),
                   [["all", "Stop all"], ["session", "Stop session only"], ["cancel", "Cancel"]]);
  assert.equal(div.querySelectorAll(".ss-line").length, 2);
  const text = div.textContent.replace(/\s+/g, " ");
  assert.match(text, /This session still has/);
  assert.match(text, /2 things/);
  // The reason the two stops differ, said once.
  assert.match(text, /a background task or a delegate runs on its own/);
});

test("a sheet's line names at most three and says +N more; reminders say they end with the session", () => {
  const div = document.createElement("div");
  div.innerHTML = markupOf(stopSheetTemplate(stopSheetModel([
    { kind: "reminders", items: [{ id: "a", label: "a", detail: "every 5m" }, { id: "b", label: "b", detail: "every 1h" }] },
    { kind: "background_tasks", items: [task("t1", "sleep 1", "1m"), task("t2", "sleep 2", "2m"),
                                        task("t3", "sleep 3", "3m"), task("t4", "sleep 4", "4m")] },
  ])));
  const text = div.textContent.replace(/\s+/g, " ");

  assert.match(text, /2 reminders \(they end with the session\) a \(every 5m\) · b \(every 1h\)/);
  assert.match(text, /4 background tasks sleep 1 \(1m\) · sleep 2 \(2m\) · sleep 3 \(3m\) \+1 more/);
  assert.equal(div.querySelectorAll(".ss-more").length, 1);
});

test("the sheet opens at the Stop button for something to stop, and not for nothing", () => {
  const doc = document;
  const button = doc.createElement("button");
  button.id = "infoStopBtn";
  doc.body.appendChild(button);
  const calls = [];
  const sheet = createStopSheet({ doc, win: { innerWidth: 1024, innerHeight: 768 },
                                  stopAll: (id) => calls.push(["all", id]),
                                  stopSession: (id) => calls.push(["session", id]) });

  assert.equal(sheet.open("s1", []), false);
  assert.equal(sheet.isOpen(), false);
  assert.equal(sheet.open("s1", holds()), true);
  assert.equal(sheet.isOpen(), true);
  const text = sheet.pop.textContent.replace(/\s+/g, " ");
  assert.match(text, /This session still has/);
  assert.match(text, /2 things/);
  assert.match(text, /1 background task npm test \(3m\)/);
  assert.match(text, /1 delegate ab12cd34 "fix the grip" running a turn/);

  sheet.pop.querySelector('[data-act="all"]').click();
  assert.deepEqual(calls, [["all", "s1"]]);
  assert.equal(sheet.isOpen(), false);

  sheet.open("s2", holds());
  sheet.pop.querySelector('[data-act="session"]').click();
  assert.deepEqual(calls, [["all", "s1"], ["session", "s2"]]);
  assert.equal(sheet.isOpen(), false);

  sheet.open("s3", holds());
  sheet.pop.querySelector('[data-act="cancel"]').click();
  assert.deepEqual(calls, [["all", "s1"], ["session", "s2"]]);
  assert.equal(sheet.isOpen(), false);
  button.remove();
});
