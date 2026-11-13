import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// The owner page on a phone runs under the notch and the home indicator
// (viewport-fit=cover) and keeps clear of them through --safe-*, which read
// the safe areas (env()) and which the e2e set by hand (a desktop browser
// has none). The page's height is the dynamic viewport's (a Safari tab's
// toolbar comes and goes), with 100vh first for a browser without dvh.
const PUBLIC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../lib/samagotchi/web/public");
const HTML = fs.readFileSync(path.join(PUBLIC, "index.html"), "utf8");

test("safe areas: the viewport covers the whole screen", () => {
  assert.match(HTML, /<meta name="viewport" content="[^"]*\bviewport-fit=cover\b[^"]*">/);
});

test("safe areas: each --safe-* side reads its env() inset, 0 without one", () => {
  for (const [side, inset] of [["t", "top"], ["r", "right"], ["b", "bottom"], ["l", "left"]]) {
    assert.ok(HTML.includes(`--safe-${side}:env(safe-area-inset-${inset},0px)`), `--safe-${side}`);
  }
});

test("safe areas: the body is 100vh, then 100dvh where it is known", () => {
  assert.match(HTML, /\nbody\{[^}]*height:100vh;height:100dvh;/);
});

test("safe areas: the standalone phone app keeps content below iOS's blurred top band", () => {
  assert.match(HTML, /@media \(display-mode:standalone\) and \(max-width:600px\)\{body\{padding-top:12px\}\}/);
});

test("safe areas: main pads by them, and the update sheet, the toast and the lightbox keep clear of them", () => {
  const main = HTML.match(/\nmain\{([^}]*)\}/)[1];
  for (const side of ["t", "r", "b", "l"]) assert.ok(main.includes(`var(--safe-${side})`), `main --safe-${side}`);
  assert.match(HTML, /#updateSheet\{position:fixed;inset:auto 8px calc\(8px \+ var\(--safe-b\)\)/);
  assert.match(HTML, /#toast\{[^}]*bottom:var\(--toast-bottom,max\(24px,calc\(var\(--safe-b\) \+ 12px\)\)\)/);
  assert.match(HTML, /#lightbox\{[^}]*padding:var\(--safe-t\) var\(--safe-r\) var\(--safe-b\) var\(--safe-l\)/);
});
