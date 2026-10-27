import test from "node:test";
import assert from "node:assert/strict";
import { toolsOverview } from "../../../lib/samagotchi/web/public/tools_overview.js";

test("participant tools overview counts activity and names a few edited files", () => {
  assert.equal(toolsOverview([
    { tool: "read", path: "docs/plan.md" },
    { tool: "read", path: "lib/samagotchi/engine.rb" },
    { tool: "execute", command: "secret command" },
    { tool: "edit", path: "lib/samagotchi/engine.rb" },
    { tool: "write", path: "lib/samagotchi/worker.rb" },
  ]), "read 2 files · ran 1 command · edited 2 files (engine.rb, worker.rb)");
});

test("participant tools overview limits edited file names and handles other tools", () => {
  assert.equal(toolsOverview([
    { tool: "write", path: "one.rb" },
    { tool: "edit", path: "two.rb" },
    { tool: "edit", path: "three.rb" },
    { tool: "write", path: "four.rb" },
    { tool: "memory_read", name: "secret memory" },
  ]), "edited 4 files (one.rb, two.rb, three.rb, …) · used 1 other tool");
});

test("participant tools overview handles empty input without exposing command text", () => {
  assert.equal(toolsOverview([]), "");
  assert.equal(toolsOverview(null), "");
  assert.equal(toolsOverview([{ tool: "execute", command: "do not show this" }]), "ran 1 command");
});
