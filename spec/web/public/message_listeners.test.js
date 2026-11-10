import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Block renderers' hard rule 3 (docs/internals/block-renderers.md): the page's
// only window `message` listener is block_frame.js's, which takes a message
// only from its frame (frameMessage). Another one would be a second receiver
// that a renderer's frame could post to. A BroadcastChannel's or an
// EventSource's onmessage isn't a window listener.
const PUBLIC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../lib/samagotchi/web/public");
// file → how many: block_frame.js's onMessage, and its BOOTSTRAP's, which runs
// in the frame, not the page.
const ALLOWED = { "block_frame.js": 2 };
const LISTENER = /addEventListener\(\s*["'`]message["'`]|\b(?:window|self|globalThis|win|top|parent)\.onmessage\s*=/g;

function jsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return jsFiles(full);
    return entry.name.endsWith(".js") ? [full] : [];
  });
}

test("no window message listener but block_frame.js's", () => {
  const found = {};
  for (const file of jsFiles(PUBLIC)) {
    const count = (fs.readFileSync(file, "utf8").match(LISTENER) || []).length;
    if (count) found[path.relative(PUBLIC, file)] = count;
  }
  assert.deepEqual(found, ALLOWED);
});
