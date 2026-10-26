import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// The web UI's colours live in two token blocks in tokens.css, which the
// owner's page (index.html) and the participant page (participant.html)
// link: the dark :root (the default) and the light set under
// prefers-color-scheme: light. Everything else reads them through var().
const PUBLIC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../lib/samagotchi/web/public");
const TOKENS = fs.readFileSync(path.join(PUBLIC, "tokens.css"), "utf8");
const PAGES = ["index.html", "participant.html"].map((name) => [name, fs.readFileSync(path.join(PUBLIC, name), "utf8")]);
const HTML = PAGES[0][1];
// The stylesheets both pages share besides tokens.css (composer.css: the composer; forms.css: the select box).
const SHARED_CSS = ["annotate_bar.css", "composer.css", "forms.css"].map((name) => [name, fs.readFileSync(path.join(PUBLIC, name), "utf8")]);
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

const darkStart = TOKENS.indexOf(":root{") + ":root{".length;
const darkBody = blockBody(TOKENS, darkStart);
const lightAt = TOKENS.indexOf(LIGHT_OPEN);
const lightBody = lightAt < 0 ? "" : blockBody(TOKENS, lightAt + LIGHT_OPEN.length);
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

test("theme: tokens.css and the pages have no raw colour outside the token blocks", () => {
  const hits = [];
  for (const [name, text] of [["tokens.css", TOKENS], ...PAGES, ...SHARED_CSS]) {
    outsideTokens(text).split("\n").forEach((line, i) => {
      for (const m of line.matchAll(COLOUR)) hits.push(`${name} line ~${i + 1}: ${m[0]} in ${line.trim().slice(0, 120)}`);
    });
  }
  assert.deepEqual(hits, []);
});

test("theme: both pages link tokens.css, then the shared stylesheets", () => {
  for (const [name, text] of PAGES) {
    assert.match(text, /<link rel="stylesheet" href="\/assets\/tokens\.css">/, name);
    for (const [css] of SHARED_CSS) assert.ok(text.includes(`<link rel="stylesheet" href="/assets/${css}">`), `${name} links ${css}`);
  }
});

test("theme: both pages link composer.css after tokens.css and before their own <style>", () => {
  for (const [name, text] of PAGES) {
    const tokens = text.indexOf('<link rel="stylesheet" href="/assets/tokens.css">');
    const composer = text.indexOf('<link rel="stylesheet" href="/assets/composer.css">');
    assert.ok(tokens >= 0 && composer > tokens && composer < text.indexOf("<style>"), name);
  }
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

// The working set's secondary text (the rail's count, the list's header rows
// and ops text, the drop/pin buttons) and the rail's rule: one step brighter
// on the dark palette, where text-faint and border read as almost nothing;
// the light palette keeps the base tokens.
test("theme: the working set's faint text and rule are a step brighter on dark, unchanged on light", () => {
  assert.equal(DARK["--ws-faint"], "var(--text-muted)");
  assert.equal(DARK["--ws-muted"], "var(--text-3)");
  assert.equal(DARK["--ws-rule"], "var(--border-strong)");
  assert.equal(LIGHT["--ws-faint"], "var(--text-faint)");
  assert.equal(LIGHT["--ws-muted"], "var(--text-muted)");
  assert.equal(LIGHT["--ws-rule"], "var(--border)");
  const rule = (selector) => HTML.slice(HTML.indexOf(`${selector}{`)).split("}")[0];
  assert.match(rule(".ts-ws"), /border-left:1px solid var\(--ws-rule\)/);
  assert.match(rule(".ws-count"), /color:var\(--ws-faint\)/);
  assert.match(rule(".ws-popover .ctx-pop-meta"), /color:var\(--ws-muted\)/);
  assert.match(rule(".ws-row .st"), /color:var\(--ws-faint\)/);
  assert.match(rule(".ws-row .tk,.ws-row .c"), /color:var\(--ws-faint\)/);
  assert.match(rule(".ws-act-b"), /color:var\(--ws-muted\)/);
});
