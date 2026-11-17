import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { moduleSources, newExports, parseExports } from "./export_ratchet.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const publicRoot = path.join(root, "lib/samagotchi/web/public");
const baselinePath = path.join(path.dirname(fileURLToPath(import.meta.url)), "exports_baseline.json");
const ALLOWED = [];

test("parses declaration exports, named exports, aliases, and re-exports", () => {
  assert.deepEqual(parseExports([
    "export function render() {}",
    "export async function load() {}",
    "export class Model {}",
    "export const VERSION = 1;",
    "export { local, original as alias } from './other.js';",
  ].join("\n")), ["Model", "VERSION", "alias", "load", "local", "render"]);
});

test("rejects export-star instead of silently missing names", () => {
  assert.throws(() => parseExports('export * from "./other.js";', "entry.js"), /entry\.js: export \* is not supported/);
});

test("only new exports on baseline modules require an allowance", () => {
  const sources = {
    "old.js": "export const EXISTING = 1; export function added() {}",
    "new.js": "export class NewModule {}",
  };
  const baseline = { "old.js": ["EXISTING"] };
  assert.deepEqual(newExports(sources, baseline), [{ file: "old.js", name: "added" }]);
  assert.deepEqual(newExports(sources, baseline, [
    { file: "old.js", name: "added", reason: "Needed by the current page wiring" },
  ]), []);
});

test("all public modules keep their baseline exports", async () => {
  const sources = await moduleSources(publicRoot);
  const baseline = JSON.parse(await readFile(baselinePath, "utf8"));
  const violations = newExports(sources, baseline, ALLOWED);
  assert.equal(violations.length, 0, violations.map(({ file, name }) =>
    `${file}: new export ${name}; put it in a new module (see docs/internals/web-frontend.md, "New exports go in new modules").`
  ).join("\n"));
});
