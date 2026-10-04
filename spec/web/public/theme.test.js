import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// The web UI's colours live in two token blocks in index.html's inline
// <style>: the dark :root (the default) and the light set under
// prefers-color-scheme: light. Everything else reads them through var().
const PUBLIC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../lib/samagotchi/web/public");
const HTML = fs.readFileSync(path.join(PUBLIC, "index.html"), "utf8");
const LIGHT_OPEN = '@media (prefers-color-scheme:light){:root:not([data-theme="dark"]){';

// The text from `start` (an index just past an opening brace) to its
// matching closing brace.
function blockBody(text, start) {
  let depth = 1;
  for (let i = start; i < text.length; i++) {
    if (text[i] === "{") depth++;
    else if (text[i] === "}" && --depth === 0) return text.slice(start, i);
  }
  throw new Error("unbalanced braces");
}

// { name: value } of a block's custom properties (values hold no ";").
function tokens(body) {
  const out = {};
  for (const decl of body.split(";")) {
    const m = decl.match(/^\s*(--[\w-]+)\s*:\s*([\s\S]*?)\s*$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

const darkStart = HTML.indexOf(":root{") + ":root{".length;
const darkBody = blockBody(HTML, darkStart);
const lightAt = HTML.indexOf(LIGHT_OPEN);
const lightBody = lightAt < 0 ? "" : blockBody(HTML, lightAt + LIGHT_OPEN.length);
const DARK = tokens(darkBody);
const LIGHT = tokens(lightBody);

test("theme: the dark :root and the light set are both found", () => {
  assert.ok(Object.keys(DARK).length > 30, "dark :root tokens");
  assert.ok(lightAt > darkStart, "the light block follows the dark :root");
  assert.ok(Object.keys(LIGHT).length > 30, "light tokens");
});

test("theme: every dark token with a literal value has a light value", () => {
  // A token built from others (var(...)) follows them and needs no copy.
  const literal = Object.keys(DARK).filter((name) => !DARK[name].includes("var("));
  const missing = literal.filter((name) => !(name in LIGHT));
  assert.deepEqual(missing, []);
});

test("theme: the light set defines no token the dark :root lacks", () => {
  const extra = Object.keys(LIGHT).filter((name) => !(name in DARK));
  assert.deepEqual(extra, []);
});

const COLOUR = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(|(?<![-\w])(?:white|black|red|green|blue|gray|grey|silver|yellow|orange|purple)(?![-\w])/g;

// What may carry a colour outside the token blocks: icon masks (data: SVGs
// whose stroke only shapes the mask; the icon takes currentColor) and
// comments.
function outsideTokens(text) {
  return text
    .replace(darkBody, "")
    .replace(lightBody, "")
    .replace(/url\("data:image\/svg\+xml,[^"]*"\)/g, "url()")
    .replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, ""))
    .replace(/<!--[\s\S]*?-->/g, (c) => c.replace(/[^\n]/g, ""));
}

test("theme: index.html has no raw colour outside the token blocks", () => {
  const hits = [];
  outsideTokens(HTML).split("\n").forEach((line, i) => {
    for (const m of line.matchAll(COLOUR)) hits.push(`line ~${i + 1}: ${m[0]} in ${line.trim().slice(0, 120)}`);
  });
  assert.deepEqual(hits, []);
});

test("theme: no web JS module sets a raw colour", () => {
  const hits = [];
  for (const file of fs.readdirSync(PUBLIC).filter((f) => f.endsWith(".js"))) {
    const src = fs.readFileSync(path.join(PUBLIC, file), "utf8");
    src.split("\n").forEach((line, i) => {
      if (/^\s*\/\//.test(line)) return;
      for (const m of line.matchAll(/["'`][^"'`]*?(#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\()/g)) hits.push(`${file}:${i + 1}: ${m[1]}`);
    });
  }
  assert.deepEqual(hits, []);
});
