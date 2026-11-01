import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Frames (docs/internals/web-frontend.md): a running turn's cost is its update
// rate. An animation that never ends is stepped, and moves opacity or transform
// only. Unstepped, it draws every frame; a paint property (box-shadow, a
// background) repaints on each of them.
const PUBLIC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../lib/samagotchi/web/public");
const SOURCES = ["index.html", "participant.html", ...fs.readdirSync(PUBLIC).filter((name) => name.endsWith(".css"))];
const CHEAP = new Set(["opacity", "transform"]);
// Shown only while a list loads, which ends by itself.
const ALLOWED = [".card.skeleton"];

// The stylesheet text with its comments gone: a page's <style> blocks, a file whole.
function cssOf(name) {
  const text = fs.readFileSync(path.join(PUBLIC, name), "utf8");
  const css = name.endsWith(".css") ? text : [...text.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n");
  return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

// { keyframes name: its properties }, across every source (a page's rule may
// use another file's keyframes).
function keyframesOf(css) {
  const found = {};
  for (const m of css.matchAll(/@keyframes\s+([\w-]+)\s*\{((?:[^{}]*\{[^{}]*\})*)\s*\}/g)) {
    found[m[1]] = [...m[2].matchAll(/\{([^{}]*)\}/g)]
      .flatMap((step) => step[1].split(";"))
      .map((decl) => decl.split(":")[0].trim())
      .filter(Boolean);
  }
  return found;
}

// Every rule that sets an animation with "infinite": {selector, animation}.
function infiniteRules(css) {
  const rules = [];
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const decl = m[2].split(";").map((d) => d.trim()).find((d) => /^animation(-iteration-count)?\s*:/.test(d) && /\binfinite\b/.test(d));
    if (decl) rules.push({ selector: m[1].trim(), animation: decl.slice(decl.indexOf(":") + 1).trim() });
  }
  return rules;
}

const sheets = SOURCES.map((name) => [name, cssOf(name)]);
const keyframes = Object.assign({}, ...sheets.map(([, css]) => keyframesOf(css)));

// What a rule breaks, as words (none: fine).
function offenses({ animation }) {
  const name = animation.split(/\s+/).find((word) => keyframes[word]);
  if (!name) return [`no keyframes for "${animation}"`];
  const out = [];
  if (!/\bsteps\(/.test(animation)) out.push("not stepped");
  const paint = keyframes[name].filter((prop) => !CHEAP.has(prop));
  if (paint.length) out.push(`${name} moves ${paint.join(", ")}`);
  return out;
}

test("the check sees what it guards: the stage's live animations, a stepped one and the allowed skeleton", () => {
  const selectors = sheets.flatMap(([, css]) => infiniteRules(css)).map((rule) => rule.selector);
  for (const selector of [".ts-mark", ".ts-tick.running", ".ts-spin", ".init-spin", ".gen.live>summary::before", ...ALLOWED]) {
    assert.ok(selectors.includes(selector), `${selector} not found among ${selectors.join(" | ")}`);
  }
  assert.deepEqual(offenses({ animation: "live-blink 2.4s ease infinite" }), ["not stepped"]);
  keyframes.painted = ["box-shadow"];
  try {
    assert.deepEqual(offenses({ animation: "painted 1s steps(4) infinite" }), ["painted moves box-shadow"]);
  } finally {
    delete keyframes.painted;
  }
});

for (const [name, css] of sheets) {
  test(`${name}: an infinite animation is stepped and moves opacity or transform only`, () => {
    const bad = infiniteRules(css)
      .filter((rule) => !ALLOWED.includes(rule.selector))
      .flatMap((rule) => offenses(rule).map((why) => `${rule.selector}: ${why}`));
    assert.deepEqual(bad, []);
  });
}

test("prefers-reduced-motion stops every infinite animation but the allowed ones", () => {
  const css = sheets.map(([, text]) => text).join("\n");
  const stopped = [...css.matchAll(/@media\s*\(prefers-reduced-motion:reduce\)\s*\{((?:[^{}]*\{[^{}]*\})*)\s*\}/g)]
    .flatMap((m) => [...m[1].matchAll(/([^{}]+)\{[^{}]*\banimation:none\b[^{}]*\}/g)])
    .flatMap((m) => m[1].split(",").map((selector) => selector.trim()));
  const missing = sheets.flatMap(([, text]) => infiniteRules(text))
    .map((rule) => rule.selector)
    .filter((selector) => !ALLOWED.includes(selector) && !stopped.includes(selector));
  assert.deepEqual(missing, []);
});

test("the pulse's timing: the dot and tick 13 updates/s, the spinners 20", () => {
  const rules = infiniteRules(sheets[0][1]);
  const animationOf = (selector) => rules.find((rule) => rule.selector === selector)?.animation;
  for (const selector of [".ts-mark", ".ts-tick.running", ".gen.live>summary::before"]) {
    assert.equal(animationOf(selector), "live-blink 2.4s steps(16) infinite", selector);
  }
  for (const selector of [".ts-spin", ".init-spin", ".turn-work:not(.done) .activity-status.running::before"]) {
    assert.equal(animationOf(selector), "init-spin .8s steps(16) infinite", selector);
  }
});
