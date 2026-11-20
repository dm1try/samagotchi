// A refused delete's or archive's background tasks in the page's words
// (running_tasks.js): the line, the second confirm, the toast's suffix.
import test from "node:test";
import assert from "node:assert/strict";
import { tasksConfirmText, tasksCount, tasksLine, tasksStoppedSuffix } from "../../../lib/samagotchi/web/public/running_tasks.js";


test("tasksConfirmText: the second confirm names the running tasks and the op", () => {
  const one = { running: [{ session_id: "ab12cd34-1", id: "20261120-3f9a2c1d", command: "npm run dev" }] };
  assert.equal(tasksConfirmText("ab12cd34-1", one, "archive"),
               "Session ab12cd34 started 1 background task that is still running:\nnpm run dev\nStop it and archive the session?");
  const two = { running: [...one.running, { session_id: "ab12cd34-1", id: "x-2", command: "rspec" }], unverified: [], unreadable: [] };
  assert.equal(tasksConfirmText("ab12cd34-1", two, "delete"),
               "Session ab12cd34 started 2 background tasks that are still running:\nnpm run dev · rspec\nStop them and delete the session?");
});

test("tasksStoppedSuffix: what a delete's or an archive's toast adds for the tasks it stopped", () => {
  assert.equal(tasksStoppedSuffix({}), "");
  assert.equal(tasksStoppedSuffix({ tasks_stopped: [{ id: "a" }, { id: "b" }], tasks_not_stopped: [] }), " · stopped 2 background tasks");
  assert.equal(tasksStoppedSuffix({ session_id: "s1", tasks_stopped: [{ id: "a" }],
                                    tasks_not_stopped: [{ session_id: "s1", id: "t-1", command: "npm run dev" }] }),
               " · stopped 1 background task · 1 not stopped: npm run dev");
});


test("tasksLine: commands cut as the sheet cuts them, at most MAX_NAMED then +N more", () => {
  const long = "bundle exec rspec spec/some/very/long/path/to/a_spec.rb --seed 1";
  const tasks = ["npm run dev", long, "rspec", "rails s"].map((command, i) => ({ session_id: "s1", id: `t-${i}`, command }));
  assert.equal(tasksLine({ running: tasks }, "s1"), `npm run dev · ${long.slice(0, 42)}… · rspec +1 more`);
  assert.equal(tasksCount({ running: tasks, unverified: [{ id: "x" }] }), 5);
});

test("tasksLine: a delegate's task carries its short id; unverified and unreadable records are named by id", () => {
  const line = tasksLine({
    running: [{ session_id: "9d0e1f2a-0000", id: "t-1", command: "rspec" }],
    unverified: [{ session_id: "s1", id: "20261001120000-3f9a2c1d", command: "sleep 9" }],
    unreadable: [{ session_id: "s1", id: "20261001120000-0badf00d", command: null }],
  }, "s1");
  assert.equal(line, "9d0e1f2a: rspec · task 3f9a2c1d (may still be running) · task 0badf00d (record unreadable)");
  assert.equal(tasksLine([{ session_id: "s1", id: "t-9", command: "  " }]), "task 9");
});
