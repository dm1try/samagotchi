// The e2e suite's env.js, loaded the way `npm run e2e` under `git rebase --exec`
// or a hook does: what git inherited there must not reach the chi it starts, nor
// any process of the suite.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";

const ENV_JS = new URL("../../e2e/support/env.js", import.meta.url).href;

test("loading the e2e env clears every variable that tells a git which repo to act on", () => {
  const local = execFileSync("git", ["rev-parse", "--local-env-vars"], { encoding: "utf8" }).split("\n").filter(Boolean);
  assert.ok(local.includes("GIT_DIR"));
  // A path that doesn't exist: nothing here may reach a real repo even if it fails.
  const inherited = Object.fromEntries(local.map((name) => [name, "/nowhere/from-e2e-env-test"]));
  const script = `await import(${JSON.stringify(ENV_JS)}); console.log(Object.keys(process.env).filter((k) => k.startsWith("GIT_")).join(" "));`;
  const out = execFileSync(process.execPath, ["--input-type=module", "-e", script],
    { encoding: "utf8", env: { ...process.env, ...inherited, GIT_CONFIG_COUNT: "0", GIT_EDITOR: "true" } });
  const left = out.trim().split(/\s+/);
  assert.deepEqual(local.filter((name) => left.includes(name)), []);
  assert.ok(left.includes("GIT_EDITOR"), "only those: a git setting of the user's stays");
});
