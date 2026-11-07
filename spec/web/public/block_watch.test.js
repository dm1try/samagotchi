import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createBlockHost } from "../../../lib/samagotchi/web/public/block_host.js";
import { createBlockWatch, rejoin } from "../../../lib/samagotchi/web/public/block_watch.js";
import { DRAWN, figureOf } from "../../../lib/samagotchi/web/public/block_source.js";

const SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 90"><text>hi</text></svg>';
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const answer = (body) => `<div class="bubble output markdown">${body}</div>`;
const block = (src, lang) => `<pre data-lang="${lang}"><code>${src}</code></pre>`;

// A core drawer as P1b's will be: no list, a figure of its own.
function coreDrawer(lang, drawn = []) {
  return {
    claims: (l) => l === lang,
    needsDraw: (_pre, figure) => !figure,
    draw(pre) {
      const figure = document.createElement("figure");
      figure.className = DRAWN;
      pre.before(figure);
      pre.hidden = true;
      drawn.push(pre);
    },
  };
}

function makeRoot(html) {
  const root = document.createElement("div");
  root.innerHTML = html;
  document.body.append(root);
  return root;
}

function hostWith(root, { drawers, listRenderers, renders }) {
  return createBlockHost({
    roots: [root],
    sessionId: () => "s1",
    drawers,
    listRenderers,
    fetchFile: async () => "",
    makeFrame: () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: async (source) => { renders.push(source); return SVG; } }),
    decodeImage: async () => ({ width: 320, height: 90 }),
    theme: () => ({ name: "dark" }),
    watch: (_el, _scroller, onNear) => onNear(),
    storage: { has: () => false, set() {}, remove() {} },
    win: window,
  });
}

test.afterEach(() => { document.body.innerHTML = ""; });

test("a core drawer claims its language before the renderer list loads; a bundle language waits for it", async () => {
  let loaded;
  const listRenderers = () => new Promise((resolve) => { loaded = resolve; });
  const drawn = [];
  const renders = [];
  const root = makeRoot(answer(block("a: 1", "chi-ui") + block("graph TD", "mermaid")));
  hostWith(root, { drawers: [coreDrawer("chi-ui", drawn)], listRenderers, renders });
  await settle();
  const [core, mermaid] = root.querySelectorAll("pre");
  assert.deepEqual(drawn, [core]);
  assert.ok(figureOf(core));
  assert.ok(!figureOf(mermaid));
  assert.equal(renders.length, 0);

  loaded([{ lang: "mermaid", bundle: "b", files: ["a.js"] }]);
  await settle();
  await settle();
  assert.deepEqual(renders, ["graph TD"]);
  assert.ok(figureOf(mermaid));
  assert.equal(drawn.length, 1);
});

test("an unclaimed language is ignored, by the core drawers and the list alike", async () => {
  const drawn = [];
  const renders = [];
  const root = makeRoot(answer(block("x = 1", "ruby")));
  hostWith(root, { drawers: [coreDrawer("chi-ui", drawn)], listRenderers: async () => [{ lang: "mermaid", bundle: "b", files: ["a.js"] }], renders });
  await settle();
  assert.equal(drawn.length, 0);
  assert.equal(renders.length, 0);
  assert.ok(!root.querySelector("figure, .block-note"));
  assert.equal(root.querySelector("pre").hidden, false);
});

test("a core drawer goes first, even for a language the list also claims", async () => {
  const drawn = [];
  const renders = [];
  const root = makeRoot(answer(block("graph TD", "mermaid")));
  hostWith(root, { drawers: [coreDrawer("mermaid", drawn)], listRenderers: async () => [{ lang: "mermaid", bundle: "b", files: ["a.js"] }], renders });
  await settle();
  assert.equal(drawn.length, 1);
  assert.equal(renders.length, 0);
});

test("the watcher asks the next drawer when an asynchronous one says no", async () => {
  const asked = [];
  const drawn = [];
  const later = { claims: (lang) => { asked.push(lang); return Promise.resolve(false); }, needsDraw: () => true, draw() { throw new Error("not mine"); } };
  const root = makeRoot(answer(block("a: 1", "chi-ui")));
  createBlockWatch({ roots: [root], sessionId: () => "s1", drawers: [later, coreDrawer("chi-ui", drawn)], watch: (_el, _s, onNear) => onNear(), win: window });
  await settle();
  assert.deepEqual(asked, ["chi-ui"]);
  assert.equal(drawn.length, 1);
});

test("the guards hold for every drawer: an empty fence, a failed block, text outside TEXTS", async () => {
  const drawn = [];
  const root = makeRoot([
    answer(block("  ", "chi-ui")),
    answer('<pre data-lang="chi-ui" data-block-failed="1">a: 1</pre>'),
    `<div class="bubble plugin-card">${block("a: 1", "chi-ui")}</div>`,
  ].join(""));
  createBlockWatch({ roots: [root], sessionId: () => "s1", drawers: [coreDrawer("chi-ui", drawn)], watch: (_el, _s, onNear) => onNear(), win: window });
  await settle();
  assert.equal(drawn.length, 0);
});

test("a session change tells the drawers; a draw's reconsider looks at the block again", async () => {
  let session = "s1";
  let changed = 0;
  let draws = 0;
  const drawer = {
    claims: () => true,
    needsDraw: () => true,
    sessionChanged: () => { changed += 1; },
    async draw(pre, { reconsider }) {
      draws += 1;
      if (draws === 1) reconsider(pre);
    },
  };
  const root = makeRoot(answer(block("a: 1", "chi-ui")));
  createBlockWatch({ roots: [root], sessionId: () => session, drawers: [drawer], watch: (_el, _s, onNear) => onNear(), win: window });
  await settle();
  assert.equal(draws, 2);
  session = "s2";
  root.insertAdjacentHTML("beforeend", "<p>x</p>");
  await settle();
  assert.equal(changed, 1);
});

test("rejoin puts a figure back with its pre inside a code wrap", () => {
  const root = makeRoot(`<figure class="${DRAWN}"></figure><div class="code-wrap"><pre data-lang="x" hidden>a</pre></div>`);
  const pre = root.querySelector("pre");
  rejoin(pre);
  assert.ok(figureOf(pre));
});

test("a drawer that throws or rejects fails its block with a line; the rest of the batch draws", async (t) => {
  const errors = t.mock.method(console, "error", () => {});
  const drawn = [];
  const throwing = { claims: (l) => l === "bad", needsDraw: () => true, draw() { throw new Error("broke at once"); } };
  const rejecting = { claims: (l) => l === "later", needsDraw: () => true, draw: async () => { throw new Error("broke later"); } };
  const root = makeRoot(answer(block("a", "bad") + block("b", "chi-ui") + block("c", "later")));
  const batch = [];
  createBlockWatch({ roots: [root], sessionId: () => "s1", drawers: [throwing, rejecting, coreDrawer("chi-ui", drawn)], watch: (_el, _s, onNear) => batch.push(onNear), win: window });
  for (const onNear of batch) onNear(); // one observer batch
  await settle();
  const [bad, good, later] = root.querySelectorAll("pre");
  assert.deepEqual(drawn, [good]);
  for (const [pre, words] of [[bad, "broke at once"], [later, "broke later"]]) {
    assert.equal(pre.dataset.blockFailed, "1");
    assert.match(pre.nextElementSibling.dataset.text, new RegExp(words));
  }
  assert.equal(errors.mock.callCount(), 2);
});

test("a throw after an asynchronous claim fails the block instead of going unhandled", async (t) => {
  const errors = t.mock.method(console, "error", () => {});
  const drawer = { claims: () => Promise.resolve(true), needsDraw() { throw new Error("needsDraw broke"); }, draw() {} };
  const root = makeRoot(answer(block("a", "x")));
  createBlockWatch({ roots: [root], sessionId: () => "s1", drawers: [drawer], watch: (_el, _s, onNear) => onNear(), win: window });
  await settle();
  const pre = root.querySelector("pre");
  assert.equal(pre.dataset.blockFailed, "1");
  assert.match(root.querySelector(".block-note").dataset.text, /needsDraw broke/);
  assert.equal(errors.mock.callCount(), 1);
});
