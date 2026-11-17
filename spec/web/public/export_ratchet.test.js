import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  formatViolations,
  moduleSources,
  newExports,
  parseExports,
  writeExportsBaseline,
} from "./export_ratchet.js";

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
    "// export let ignored = true;",
    "const example = 'export default ignored';",
  ].join("\n")), ["Model", "VERSION", "alias", "load", "local", "render"]);
});

test("rejects export-star instead of silently missing names", () => {
  assert.throws(() => parseExports('export * from "./other.js";', "entry.js"), /entry\.js: export \* is not supported/);
});

test("only new exports on baseline modules require an allowance", async () => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), "export-ratchet-"));
  try {
    const publicRoot = path.join(tempRoot, "public");
    const baselinePath = path.join(tempRoot, "exports_baseline.json");
    await mkdir(publicRoot);
    await writeFile(path.join(publicRoot, "old.js"), "export const EXISTING = 1; export function added() {}");
    await writeFile(path.join(publicRoot, "new.js"), "export class NewModule {}");
    await writeFile(baselinePath, JSON.stringify({ "old.js": ["EXISTING"] }));
    const sources = await moduleSources(publicRoot);
    const baseline = JSON.parse(await readFile(baselinePath, "utf8"));
    const violations = newExports(sources, baseline);
    assert.deepEqual(violations, [{ file: "old.js", name: "added" }]);
    assert.equal(formatViolations(violations),
      'old.js: new export added; put it in a new module (see docs/internals/web-frontend.md, "New exports go in new modules").');
    assert.deepEqual(newExports(sources, baseline, [
      { file: "old.js", name: "added", reason: "Needed by the current page wiring" },
    ]), []);
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("all public modules keep their baseline exports", async () => {
  const sources = await moduleSources(publicRoot);
  const baseline = JSON.parse(await readFile(baselinePath, "utf8"));
  const violations = newExports(sources, baseline, ALLOWED);
  assert.equal(violations.length, 0, formatViolations(violations));
});

test("baseline writer sorts exports and skips vendor modules", async () => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), "exports-baseline-"));
  try {
    const publicRoot = path.join(tempRoot, "lib/samagotchi/web/public");
    await mkdir(path.join(publicRoot, "vendor"), { recursive: true });
    await mkdir(path.join(tempRoot, "spec/web/public"), { recursive: true });
    await writeFile(path.join(publicRoot, "module.js"), "export const ZED = 1; export function alpha() {}");
    await writeFile(path.join(publicRoot, "vendor/library.js"), "export const INTERNAL = 1;");
    await writeExportsBaseline(tempRoot);
    const baseline = JSON.parse(await readFile(path.join(tempRoot, "spec/web/public/exports_baseline.json"), "utf8"));
    assert.deepEqual(baseline, { "module.js": ["ZED", "alpha"] });
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
});
