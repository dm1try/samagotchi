import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  CACHE_SIZE, createBlockHost, emptyPicture, fetchRendererFile, MARK_PREFIX, MAX_PICTURE_PIXELS, MAX_PICTURE_SIDE, MAX_SOURCE_BYTES, minShownWidth, oversize, pictureOf, SLOW_RENDER_MS, sourceHash,
} from "../../../lib/samagotchi/web/public/block_host.js";
import { figureOf } from "../../../lib/samagotchi/web/public/block_source.js";
import { revealInHistory } from "../../../lib/samagotchi/web/public/history_reveal.js";
import { showClaim } from "../../../lib/samagotchi/web/public/claim_link.js";

const SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 320 90"><text>hi</text></svg>';
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function fakeFrame({ svg = SVG, throwing = null, calls, frames }) {
  return () => {
    const frame = {
      dropped: false,
      ready: Promise.resolve(),
      dead: () => frame.dropped,
      drop() { frame.dropped = true; },
      async render(source, theme, { onStart }) {
        onStart();
        calls.push({ source, theme, marks: frame.marks?.() });
        if (throwing) throw throwing;
        return svg;
      },
    };
    frames.push(frame);
    return frame;
  };
}

function memoryStorage(initial = []) {
  const keys = new Set(initial);
  return { keys, has: (k) => keys.has(k), set: (k) => keys.add(k), remove: (k) => keys.delete(k) };
}

function setup(html, opts = {}) {
  const root = document.createElement("div");
  root.id = "history";
  root.innerHTML = html;
  document.body.append(root);
  const calls = [];
  const frames = [];
  const near = [];
  let session = opts.session ?? "s1";
  const storage = opts.storage || memoryStorage();
  const host = createBlockHost({
    roots: [root],
    sessionId: () => session,
    listRenderers: opts.listRenderers || (async () => [{ lang: "mermaid", bundle: "b", files: ["a.js"] }]),
    fetchFile: async () => "",
    makeFrame: opts.makeFrame || fakeFrame({ ...opts, calls, frames }),
    decodeImage: opts.decodeImage || (async () => ({ width: 320, height: 90 })),
    copy: opts.copy,
    decodeTimeoutMs: opts.decodeTimeoutMs ?? 1000,
    theme: opts.theme || (() => ({ name: "dark" })),
    watch: opts.lazy ? (el, scroller, onNear) => near.push({ el, scroller, onNear }) : (_el, _scroller, onNear) => onNear(),
    win: window,
    storage,
  });
  return { root, host, calls, frames, near, storage, setSession: (id) => { session = id; } };
}

const answer = (body, cls = "bubble output markdown") => `<div class="${cls}">${body}</div>`;
const block = (src = "graph TD\nA-->B\n", lang = "mermaid") => `<pre class="syntax-highlighting" data-lang="${lang}"><code>${src.replaceAll(">", "&gt;")}</code></pre>`;

test.afterEach(() => { document.body.innerHTML = ""; });

test("draws a block in an answer: a figure before the pre, the pre hidden, an img with a data: URL sized from the viewBox", async () => {
  const { root, calls } = setup(answer(block()));
  await settle();
  const pre = root.querySelector("pre");
  const figure = figureOf(pre);
  assert.ok(figure);
  assert.equal(pre.hidden, true);
  assert.equal(calls[0].source, "graph TD\nA-->B\n");
  const img = figure.querySelector("img");
  assert.match(img.getAttribute("src"), /^data:image\/svg\+xml/);
  assert.equal(img.getAttribute("width"), "320");
  assert.equal(img.getAttribute("height"), "90");
});

test("the frame's output never reaches the page's DOM as markup", async () => {
  const { root } = setup(answer(block()), { svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><script>x()</script><foreignObject><b id="evil">x</b></foreignObject></svg>' });
  await settle();
  assert.ok(!root.querySelector("script"));
  assert.ok(!root.querySelector("#evil"));
  assert.ok(!root.querySelector(".block-scroll svg"));
});

test("the bubble's text doesn't change: the toggle has an icon and a label, no text", async () => {
  const { root } = setup(answer(`<p>before</p>${block()}<p>after</p>`));
  const before = root.textContent;
  await settle();
  assert.equal(root.textContent, before);
  const toggle = root.querySelector(".block-toggle");
  assert.equal(toggle.textContent.trim(), "");
  assert.equal(toggle.getAttribute("aria-label"), "Show the source");
});

test("draws in a closed step's text, and not in a live step's", async () => {
  const { root } = setup(`<details class="gen"><div class="gen-text markdown">${block()}</div></details><details class="gen live"><div class="gen-text markdown">${block("other")}</div></details>`);
  await settle();
  const [closed, live] = root.querySelectorAll("pre");
  assert.ok(figureOf(closed));
  assert.ok(!figureOf(live));
});

test("leaves a pre[data-lang] in a card, a question reply, a lead-in bubble or a delegate report untouched", async () => {
  const { root, calls } = setup([
    `<div class="bubble plugin-card">${block()}</div>`,
    `<div class="bubble question">${block()}</div>`,
    `<div class="bubble said"><div class="said-text markdown">${block()}</div></div>`,
    `<div class="bubble user" data-source="delegate_report"><div class="user-message markdown">${block()}</div></div>`,
  ].join(""));
  await settle();
  assert.equal(calls.length, 0);
  assert.ok(!root.querySelector("figure"));
  for (const pre of root.querySelectorAll("pre")) assert.equal(pre.hidden, false);
});

test("leaves a language with no renderer and an empty fence alone", async () => {
  const { root, calls } = setup(answer(block("x = 1", "ruby") + block("  \n")));
  await settle();
  assert.equal(calls.length, 0);
  assert.ok(!root.querySelector("figure, .block-note"));
});

test("asks for the list once per page load, and only when a block first appears", async () => {
  let asked = 0;
  const listRenderers = async () => { asked += 1; return [{ lang: "mermaid", bundle: "b", files: ["a.js"] }]; };
  const { root } = setup('<div class="bubble output">plain</div>', { listRenderers });
  await settle();
  assert.equal(asked, 0);
  root.querySelector(".bubble").innerHTML = block("a") + block("b");
  await settle();
  root.querySelector(".bubble").insertAdjacentHTML("beforeend", block("c"));
  await settle();
  assert.equal(asked, 1);
  assert.equal(root.querySelectorAll("figure").length, 3);
});

test("a failed list means no drawing, no note, and no asking again", async () => {
  let asked = 0;
  const { root } = setup(answer(block()), { listRenderers: async () => { asked += 1; throw new Error("403"); } });
  await settle();
  assert.ok(!root.querySelector("figure, .block-note"));
  assert.equal(root.querySelector("pre").hidden, false);
  root.querySelector(".bubble").insertAdjacentHTML("beforeend", block("again\n"));
  await settle();
  assert.equal(asked, 1);
});

test("a failure keeps the source, with one muted line holding the message's first line, as text", async () => {
  const { root, storage } = setup(answer(block()), { throwing: new Error("Parse error <b>on</b> line 2\nlong detail") });
  await settle();
  const pre = root.querySelector("pre");
  assert.equal(pre.hidden, false);
  assert.ok(!figureOf(pre));
  const notes = root.querySelectorAll(".block-note");
  assert.equal(notes.length, 1);
  assert.equal(notes[0].dataset.text, "Couldn't draw this mermaid block: Parse error <b>on</b> line 2");
  assert.equal(notes[0].getAttribute("aria-label"), notes[0].dataset.text);
  assert.ok(!notes[0].querySelector("b"));
  assert.equal(storage.keys.size, 0);
});

test("an image the browser can't decode counts as a failure", async () => {
  const { root } = setup(answer(block()), { decodeImage: async () => { throw new Error("bad image"); } });
  await settle();
  assert.ok(!root.querySelector("figure"));
  assert.match(root.querySelector(".block-note").dataset.text, /can't be shown as an image/);
});

test("a failed block isn't tried again when its nodes move", async () => {
  const { root, calls } = setup(answer(block()), { throwing: new Error("nope") });
  await settle();
  const pre = root.querySelector("pre");
  const wrap = document.createElement("div");
  wrap.className = "code-wrap";
  pre.replaceWith(wrap);
  wrap.append(pre);
  await settle();
  assert.equal(calls.length, 1);
  assert.equal(root.querySelectorAll(".block-note").length, 1);
});

test("a source over the limit stays source, without a render", async () => {
  const { root, calls } = setup(answer(block("x".repeat(MAX_SOURCE_BYTES + 1))));
  await settle();
  assert.equal(calls.length, 0);
  assert.ok(!root.querySelector("figure"));
  assert.equal(root.querySelector("pre").hidden, false);
});

test("a mark left by an earlier load keeps that block source, with its line; another block draws", async () => {
  const src = "graph TD\nA-->B\n";
  const storage = memoryStorage([`${MARK_PREFIX}mermaid:${sourceHash(src)}`]);
  const { root, calls } = setup(answer(block(src) + block("other\n")), { storage });
  await settle();
  const [left, drawn] = root.querySelectorAll("pre");
  assert.equal(left.hidden, false);
  assert.match(left.nextElementSibling.dataset.text, /Couldn't draw this mermaid block/);
  assert.ok(figureOf(drawn));
  assert.deepEqual(calls.map((c) => c.source), ["other\n"]);
});

test("the mark is on while the renderer runs and gone after", async () => {
  const storage = memoryStorage();
  let during = null;
  const makeFrame = () => ({
    ready: Promise.resolve(), dead: () => false, drop() {},
    async render(_s, _t, { onStart }) { onStart(); during = [...storage.keys]; return SVG; },
  });
  setup(answer(block()), { storage, makeFrame });
  await settle();
  assert.equal(during.length, 1);
  assert.ok(during[0].startsWith(MARK_PREFIX));
  assert.equal(storage.keys.size, 0);
});

test("a timeout's mark stays, so the next load leaves the block; a dropped frame's doesn't", async () => {
  const timedOut = Object.assign(new Error("timed out"), { timedOut: true });
  const a = setup(answer(block()), { throwing: timedOut });
  await settle();
  assert.equal(a.storage.keys.size, 1);
  assert.equal(a.root.querySelectorAll(".block-note").length, 1);
  document.body.innerHTML = "";

  const dropped = Object.assign(new Error("dropped"), { dropped: true });
  const b = setup(answer(block()), { throwing: dropped });
  b.root.querySelector("pre").remove();
  await settle();
  assert.equal(b.storage.keys.size, 0);
  assert.ok(!b.root.querySelector(".block-note"));
});

test("a block whose frames keep dying gives up, with its line", async () => {
  const dropped = Object.assign(new Error("the frame is gone"), { dropped: true });
  const { root, calls } = setup(answer(block()), { throwing: dropped });
  for (let i = 0; i < 10; i++) await settle();
  assert.equal(calls.length, 6);
  assert.match(root.querySelector(".block-note").dataset.text, /keeps stopping/);
  assert.equal(root.querySelector("pre").hidden, false);
});

test("a failure's line stays out of the bubble's text", async () => {
  const { root } = setup(answer(`<p>before</p>${block()}`), { throwing: new Error("nope") });
  const before = root.textContent;
  await settle();
  assert.ok(root.querySelector(".block-note"));
  assert.equal(root.textContent, before);
});

test("a block waiting to come near follows its move to another scroller, and draws once", async () => {
  const { root, near, calls } = setup(answer(`<div class="inner" style="overflow-y:auto">${block()}</div>`), { lazy: true });
  await settle();
  const inner = root.querySelector(".inner");
  const pre = root.querySelector("pre");
  assert.equal(near.length, 1);
  assert.ok(near[0].scroller === inner);
  root.querySelector(".bubble").append(pre); // the hand-off
  await settle();
  assert.equal(near.length, 2);
  assert.ok(near[1].el === pre);
  assert.ok(near[1].scroller === root);
  assert.equal(calls.length, 0);
  near[1].onNear();
  await settle();
  assert.equal(calls.length, 1);
  assert.ok(figureOf(pre));
});

test("a move within the same scroller doesn't watch again, and one during the draw doesn't either", async () => {
  let release;
  const makeFrame = () => ({
    ready: Promise.resolve(), dead: () => false, drop() {},
    render: async () => { await new Promise((r) => { release = r; }); return SVG; },
  });
  const { root, near } = setup(answer(`<div class="inner" style="overflow-y:auto">${block()}</div>`), { lazy: true, makeFrame });
  await settle();
  const pre = root.querySelector("pre");
  const inner = root.querySelector(".inner");
  const wrap = document.createElement("div");
  inner.append(wrap);
  wrap.append(pre);
  await settle();
  assert.equal(near.length, 1);
  near[0].onNear();
  await settle();
  root.querySelector(".bubble").append(pre);
  await settle();
  assert.equal(near.length, 1);
  release();
  await settle();
  assert.ok(figureOf(pre));
});

test("a reload during a render clears its mark, so a working diagram draws next load", async () => {
  const storage = memoryStorage();
  const makeFrame = () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: (_s, _t, { onStart }) => { onStart(); return new Promise(() => {}); } });
  setup(answer(block()), { storage, makeFrame });
  await settle();
  assert.equal(storage.keys.size, 1);
  window.dispatchEvent(new window.Event("pagehide"));
  assert.equal(storage.keys.size, 0);
});

test("a page stuck past the frame's timeout keeps its mark through pagehide", async (t) => {
  const storage = memoryStorage();
  const makeFrame = () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: (_s, _t, { onStart }) => { onStart(); return new Promise(() => {}); } });
  setup(answer(block()), { storage, makeFrame });
  await settle();
  assert.equal(storage.keys.size, 1);
  const real = Date.now();
  t.mock.method(Date, "now", () => real + 16000);
  window.dispatchEvent(new window.Event("pagehide"));
  assert.equal(storage.keys.size, 1);
});

test("a picture over the maximum stays source with its line, whatever the renderer, and is never decoded", async () => {
  let decoded = 0;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 ${MAX_PICTURE_SIDE + 1}"></svg>`;
  const { root, storage } = setup(answer(block()), { svg, decodeImage: async () => { decoded += 1; return { width: 1, height: 1 }; } });
  await settle();
  assert.equal(decoded, 0);
  assert.ok(!root.querySelector("figure"));
  assert.equal(root.querySelector("pre").hidden, false);
  assert.match(root.querySelector(".block-note").dataset.text, /too large to show/);
  assert.equal(storage.keys.size, 0);
});

test("the maximum holds for an SVG with no viewBox: the size it decodes to", async () => {
  const { root } = setup(answer(block()), { svg: `<svg xmlns="http://www.w3.org/2000/svg"></svg>`, decodeImage: async () => ({ width: 300, height: 90000000 }) });
  await settle();
  assert.ok(!root.querySelector("figure"));
  assert.match(root.querySelector(".block-note").dataset.text, /too large to show/);
});

test("oversize says no past either side or the area, and yes at the limit", () => {
  assert.ok(!oversize(2522, 1925));
  assert.ok(!oversize(MAX_PICTURE_SIDE, 100));
  assert.match(oversize(MAX_PICTURE_SIDE + 1, 100), /too large/);
  assert.match(oversize(100, MAX_PICTURE_SIDE + 1), /too large/);
  assert.match(oversize(MAX_PICTURE_SIDE, Math.ceil(MAX_PICTURE_PIXELS / MAX_PICTURE_SIDE) + 1), /too large/);
  assert.ok(!oversize(null, null));
});

test("a very wide picture keeps a readable height; an ordinary one is left to the column", async () => {
  assert.equal(minShownWidth(30000, 60), 30000);
  assert.equal(minShownWidth(4000, 100), 4000);
  assert.equal(minShownWidth(300, 2000), 18);
  const { root } = setup(answer(block()), { svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30000 60"></svg>' });
  await settle();
  assert.equal(root.querySelector("img").style.minWidth, "30000px");
});

test("a decode that never ends gets a bound and a line, and the mark stays until it is over", async () => {
  const storage = memoryStorage();
  let during = null;
  const decodeImage = () => { during = storage.keys.size; return new Promise(() => {}); };
  const { root } = setup(answer(block()), { storage, decodeImage, decodeTimeoutMs: 5 });
  for (let i = 0; i < 200 && !root.querySelector(".block-note"); i++) await settle();
  assert.equal(during, 1);
  assert.match(root.querySelector(".block-note").dataset.text, /too long to show/);
  assert.equal(storage.keys.size, 1);
});

test("a block taken away during its render gets no figure or line", async () => {
  let release;
  const makeFrame = () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: async () => { await new Promise((r) => { release = r; }); return SVG; } });
  const { root } = setup(answer(block()), { makeFrame });
  await settle();
  // Gone with its bubble: it still has a parent to draw into, off the page.
  const bubble = root.querySelector(".bubble");
  bubble.remove();
  release();
  await settle();
  assert.ok(!bubble.querySelector("figure, .block-note"));
});

test("a redraw that fails keeps the picture it has, with no line", async () => {
  let name = "dark";
  let throwing = false;
  const makeFrame = () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: async () => { if (throwing) throw new Error("nope"); return SVG; } });
  const { root, host } = setup(answer(block()), { theme: () => ({ name }), makeFrame });
  await settle();
  const url = root.querySelector("img").getAttribute("src");
  name = "light";
  throwing = true;
  host.scan(root);
  await settle();
  assert.equal(root.querySelector("img").getAttribute("src"), url);
  assert.ok(!root.querySelector(".block-note"));
  assert.equal(root.querySelector("pre").hidden, true);
});

test("the cache holds its cap: the oldest goes", async () => {
  const { root, calls } = setup('<div class="bubble output"></div>');
  const bubble = root.querySelector(".bubble");
  for (let i = 0; i <= CACHE_SIZE; i++) bubble.insertAdjacentHTML("beforeend", block(`src ${i}\n`));
  await settle();
  await settle();
  assert.equal(calls.length, CACHE_SIZE + 1);
  bubble.innerHTML = block("src 1\n");
  await settle();
  assert.equal(calls.length, CACHE_SIZE + 1, "a recent one is still there");
  bubble.innerHTML = block("src 0\n");
  await settle();
  assert.equal(calls.length, CACHE_SIZE + 2, "the first has gone");
});

function atGeometry(t, root, { scrollTop, scrollHeight = 2000, clientHeight = 500, preBottom, figureBottom }) {
  Object.defineProperty(root, "scrollHeight", { value: scrollHeight, configurable: true });
  Object.defineProperty(root, "clientHeight", { value: clientHeight, configurable: true });
  Object.defineProperty(root, "scrollTop", { value: scrollTop, writable: true, configurable: true });
  t.mock.method(window.Element.prototype, "getBoundingClientRect", function rect() {
    if (this === root) return { top: 0, bottom: clientHeight };
    if (this.tagName === "PRE") return { top: preBottom - 50, bottom: preBottom };
    return { top: figureBottom - 80, bottom: figureBottom };
  });
}

test("a viewer at the bottom stays at the bottom when a block draws", async (t) => {
  const { root, near } = setup(answer(block()), { lazy: true });
  await settle();
  atGeometry(t, root, { scrollTop: 1500, preBottom: 400, figureBottom: 700 });
  near[0].onNear();
  await settle();
  assert.equal(root.scrollTop, 2000);
});

test("a block drawn above a reader's view keeps what they read where it was", async (t) => {
  const { root, near } = setup(answer(block()), { lazy: true });
  await settle();
  atGeometry(t, root, { scrollTop: 800, preBottom: -100, figureBottom: 250 });
  near[0].onNear();
  await settle();
  assert.equal(root.scrollTop, 800 + 350);
});

test("a block drawn in a reader's view doesn't move it", async (t) => {
  const { root, near } = setup(answer(block()), { lazy: true });
  await settle();
  atGeometry(t, root, { scrollTop: 800, preBottom: 200, figureBottom: 500 });
  near[0].onNear();
  await settle();
  assert.equal(root.scrollTop, 800);
});

test("fetchRendererFile takes only an ok answer of a JS type", async (t) => {
  const answerWith = (ok, status, type, text = "code") => t.mock.method(globalThis, "fetch", async () => ({ ok, status, headers: { get: () => type }, text: async () => text }));
  let mock = answerWith(true, 200, "text/javascript; charset=utf-8");
  assert.equal(await fetchRendererFile("a b", "c.js"), "code");
  assert.equal(mock.mock.calls[0].arguments[0], "/api/block_renderers/a%20b/c.js");
  mock.mock.restore();
  mock = answerWith(false, 409, "application/json");
  await assert.rejects(fetchRendererFile("b", "c.js"), /answered 409/);
  mock.mock.restore();
  mock = answerWith(true, 200, "text/html", "<html>sign in</html>"); // a proxy's sign-in page
  await assert.rejects(fetchRendererFile("b", "c.js"), /isn't a script/);
  mock.mock.restore();
  mock = answerWith(true, 200, null);
  await assert.rejects(fetchRendererFile("b", "c.js"), /isn't a script/);
});

test("a block queued behind a frame that died draws in a new frame, and the one that timed out stays source", async () => {
  const timedOut = Object.assign(new Error("timed out"), { timedOut: true });
  const dropped = Object.assign(new Error("the frame is gone"), { dropped: true });
  let made = 0;
  let hangEnded;
  const hanging = new Promise((resolve) => { hangEnded = resolve; });
  // The first frame serves one render at a time: "next" waits behind "hang", as block_frame.js queues it.
  const makeFrame = () => {
    made += 1;
    const first = made === 1;
    const frame = {
      ready: Promise.resolve(), gone: false, dead: () => frame.gone, drop() { frame.gone = true; },
      async render(source, _t, { onStart }) {
        if (first && source.startsWith("hang")) {
          onStart();
          await settle();
          frame.gone = true;
          hangEnded();
          throw timedOut;
        }
        if (first) { await hanging; throw dropped; }
        onStart();
        return SVG;
      },
    };
    return frame;
  };
  const { root } = setup(answer(block("hang\n") + block("next\n")), { makeFrame });
  await settle();
  await settle();
  await settle();
  const [hung, next] = root.querySelectorAll("pre");
  assert.equal(hung.hidden, false);
  assert.match(hung.nextElementSibling.dataset.text, /timed out/);
  assert.ok(figureOf(next));
  assert.equal(made, 2);
});

function heldRender(storage) {
  const held = { renders: 0, release: null };
  held.makeFrame = () => ({
    ready: Promise.resolve(), dead: () => false, drop() {},
    render: async (_s, _t, { onStart }) => {
      held.renders += 1;
      onStart();
      await new Promise((r) => { held.release = r; });
      return SVG;
    },
  });
  held.storage = storage;
  return held;
}

test("a bubble rewritten during its block's render: the new pre gets the picture, no note, and one render", async () => {
  const held = heldRender(memoryStorage());
  const { root } = setup(answer(block()), { storage: held.storage, makeFrame: held.makeFrame });
  await settle();
  assert.equal(held.storage.keys.size, 1);
  root.querySelector(".bubble").innerHTML = block();
  await settle();
  assert.ok(!root.querySelector(".block-note"));
  held.release();
  await settle();
  const pre = root.querySelector("pre");
  assert.ok(figureOf(pre));
  assert.ok(!root.querySelector(".block-note"));
  assert.equal(held.renders, 1);
  assert.equal(held.storage.keys.size, 0);
});

test("a clone made during its block's render draws too, with no note", async () => {
  const held = heldRender(memoryStorage());
  const { root } = setup(answer(block()), { storage: held.storage, makeFrame: held.makeFrame });
  await settle();
  root.append(root.querySelector(".bubble").cloneNode(true));
  await settle();
  assert.ok(!root.querySelector(".block-note"));
  held.release();
  await settle();
  assert.equal(root.querySelectorAll("figure").length, 2);
  assert.equal(held.renders, 1);
});

test("a render that fails fails both of the blocks waiting on it", async () => {
  let release;
  const makeFrame = () => ({
    ready: Promise.resolve(), dead: () => false, drop() {},
    render: async (_s, _t, { onStart }) => { onStart(); await new Promise((r) => { release = r; }); throw new Error("nope"); },
  });
  const { root } = setup(answer(block() + block()), { makeFrame });
  await settle();
  release();
  await settle();
  assert.equal(root.querySelectorAll(".block-note").length, 2);
});

test("a mark left by this page's own timeout still keeps a later copy of the block as source", async () => {
  const timedOut = Object.assign(new Error("timed out"), { timedOut: true });
  const { root, calls } = setup(answer(block()), { throwing: timedOut });
  await settle();
  assert.equal(calls.length, 1);
  root.querySelector(".bubble").innerHTML = block();
  await settle();
  assert.equal(calls.length, 1);
  assert.match(root.querySelector(".block-note").dataset.text, /last time/);
});

test("a re-render of the bubble redraws from the cache, in the same pass", async () => {
  const { root, calls } = setup(answer(block()));
  await settle();
  assert.equal(calls.length, 1);
  const bubble = root.querySelector(".bubble");
  bubble.innerHTML = block();
  await settle();
  assert.equal(calls.length, 1);
  assert.ok(figureOf(root.querySelector("pre")));
});

test("a second scan draws nothing new", async () => {
  const { root, host, calls } = setup(answer(block()));
  await settle();
  host.scan(root);
  host.scan(root);
  await settle();
  assert.equal(calls.length, 1);
  assert.equal(root.querySelectorAll("figure").length, 1);
});

test("a Revise clone arrives with its figure: no render, and its toggle works", async () => {
  const { root, calls } = setup(answer(block()));
  await settle();
  const clone = root.querySelector(".bubble").cloneNode(true);
  root.append(clone);
  await settle();
  assert.equal(calls.length, 1);
  assert.equal(root.querySelectorAll("figure").length, 2);
  clone.querySelector(".block-toggle").click();
  assert.equal(clone.querySelector("pre").hidden, false);
  assert.equal(root.querySelector("pre").hidden, true);
});

test("a figure placed before copy.js wraps the pre joins it in the wrap", async () => {
  const { root } = setup(answer(block()));
  await settle();
  const pre = root.querySelector("pre");
  const wrap = document.createElement("div");
  wrap.className = "code-wrap";
  pre.replaceWith(wrap);
  wrap.append(pre);
  await settle();
  assert.ok(figureOf(pre)?.parentElement === wrap);
  assert.equal(root.querySelectorAll("figure").length, 1);
});

test("inside a code wrap: drawn in place, the pre still inside", async () => {
  const { root } = setup(answer(`<div class="code-wrap">${block()}<button class="copy-btn copy-code"></button></div>`));
  await settle();
  const wrap = root.querySelector(".code-wrap");
  assert.equal(wrap.firstElementChild.className, "block-drawn");
  assert.equal(wrap.querySelector("pre").hidden, true);
  assert.ok(wrap.querySelector(".copy-btn"));
});

test("the toggle swaps the picture and the source, and says so", async () => {
  const { root } = setup(answer(block()));
  await settle();
  const pre = root.querySelector("pre");
  const toggle = root.querySelector(".block-toggle");
  toggle.click();
  assert.equal(pre.hidden, false);
  assert.ok(root.querySelector("figure").classList.contains("source"));
  assert.equal(toggle.getAttribute("aria-pressed"), "true");
  toggle.click();
  assert.equal(pre.hidden, true);
  assert.equal(toggle.getAttribute("aria-pressed"), "false");
});

test("a click on the picture toggles its natural size", async () => {
  const { root } = setup(answer(block()));
  await settle();
  root.querySelector(".block-img").click();
  assert.ok(root.querySelector("figure").classList.contains("natural"));
  root.querySelector(".block-img").click();
  assert.ok(!root.querySelector("figure").classList.contains("natural"));
});

test("the picture is named with where its source is, and its zoom is a button the keyboard reaches", async () => {
  const { root } = setup(answer(block()));
  const before = root.textContent;
  await settle();
  const figure = root.querySelector("figure");
  assert.equal(figure.querySelector(".block-img").alt, "mermaid diagram, its source under the Show the source button");
  assert.equal(root.querySelector(".block-toggle").getAttribute("aria-label"), "Show the source");
  const zoom = figure.querySelector(":scope > button.block-zoom");
  assert.equal(zoom.type, "button");
  assert.equal(zoom.textContent.trim(), "");
  assert.equal(root.textContent, before);
  assert.deepEqual([zoom.getAttribute("aria-label"), zoom.getAttribute("aria-pressed")], ["Show at full size", "false"]);
  zoom.click(); // a button's Enter and Space are its click
  assert.ok(figure.classList.contains("natural"));
  assert.deepEqual([zoom.getAttribute("aria-label"), zoom.getAttribute("aria-pressed")], ["Fit to the column", "true"]);
  figure.querySelector(".block-img").click();
  assert.ok(!figure.classList.contains("natural"));
  assert.equal(zoom.getAttribute("aria-pressed"), "false", "a click on the picture keeps the button's state");
});

test("the zoom button shows on keyboard focus only, takes no pointer while hidden, and goes with the picture", async () => {
  const css = await readFile(new URL("../../../lib/samagotchi/web/public/block_renderers.css", import.meta.url), "utf8");
  assert.match(css, /\.block-zoom:focus-visible[,{]/);
  assert.match(css, /\.block-zoom:not\(:focus-visible\)\{pointer-events:none\}/);
  assert.match(css, /\.block-drawn\.source>\.block-zoom\{display:none\}/);
});

test("it waits for the block to come near the view", async () => {
  const { root, calls, near } = setup(answer(block()), { lazy: true });
  await settle();
  assert.equal(calls.length, 0);
  assert.equal(near.length, 1);
  assert.ok(near[0].el === root.querySelector("pre"));
  assert.ok(near[0].scroller === root);
  near[0].onNear();
  await settle();
  assert.equal(calls.length, 1);
});

test("a session switch drops the frames: they hold what they rendered", async () => {
  const { root, frames, setSession } = setup(answer(block()));
  await settle();
  assert.equal(frames.length, 1);
  setSession("s2");
  root.innerHTML = answer(block("new\n"));
  await settle();
  assert.equal(frames[0].dropped, true);
  assert.equal(frames.length, 2);
});

test("a language whose renderer didn't load shows every block's line, and asks once", async () => {
  let made = 0;
  const makeFrame = () => {
    made += 1;
    const ready = Promise.reject(Object.assign(new Error("answered 409"), { load: true }));
    return { ready, dead: () => true, drop() {}, render: () => ready };
  };
  const { root } = setup(answer(block("a")), { makeFrame });
  await settle();
  assert.match(root.querySelector(".block-note").dataset.text, /answered 409/);
  root.querySelector(".bubble").insertAdjacentHTML("beforeend", block("b"));
  await settle();
  assert.equal(made, 1);
  assert.equal(root.querySelectorAll(".block-note").length, 2);
});

test("a theme change redraws through the figure, keeping the source face", async () => {
  let name = "dark";
  const { root, host, calls, near } = setup(answer(block()), { theme: () => ({ name }), lazy: true });
  await settle();
  near.shift().onNear();
  await settle();
  const figure = root.querySelector("figure");
  const url = figure.querySelector("img").getAttribute("src");
  assert.equal(figure.dataset.theme, "dark");
  figure.querySelector(".block-toggle").click();

  name = "light";
  host.scan(root);
  await settle();
  assert.ok(near[0].el === figure);
  near.shift().onNear();
  await settle();
  assert.equal(calls.at(-1).theme.name, "light");
  assert.equal(figure.dataset.theme, "light");
  assert.equal(figure.querySelector("img").getAttribute("src"), url); // the fake draws the same SVG
  assert.equal(root.querySelectorAll("figure").length, 1);
  assert.equal(root.querySelector("pre").hidden, false);
});

const NS = 'xmlns="http://www.w3.org/2000/svg"';
const svgIn = ({ url }) => decodeURIComponent(url.split(",").slice(1).join(","));

test("pictureOf writes the size in from the viewBox, over a width of 100%, and encodes the rest", () => {
  const picture = pictureOf(`<svg ${NS} width="100%" style="max-width:320px" viewBox="0 0 320.5 90"><text>a$&amp;b</text></svg>`);
  assert.equal(picture.width, 320.5);
  assert.equal(picture.height, 90);
  const svg = svgIn(picture);
  assert.match(svg, /width="320.5"/);
  assert.ok(!svg.includes("100%"));
  assert.ok(svg.includes("max-width:320px"));
  assert.ok(!picture.url.includes("<"));
});

test("pictureOf leaves an SVG with no usable box to its decoded size", () => {
  for (const svg of [`<svg ${NS} width="10" height="20"></svg>`, `<svg ${NS} viewBox="nope"></svg>`, `<svg ${NS} viewBox="0 0 0 10"></svg>`]) {
    const { width, height } = pictureOf(svg);
    assert.equal(width, null);
    assert.equal(height, null);
  }
});

test("pictureOf reads the box as XML does, not as a regex would", () => {
  const box = (svg) => { const p = pictureOf(svg); return [p.width, p.height]; };
  assert.deepEqual(box(`<svg ${NS} viewBox="0 0 1e1 5e7"/>`), [10, 50000000]);
  assert.deepEqual(box(`<svg ${NS} viewBox="0,0,+10,+50000000"/>`), [10, 50000000]);
  assert.deepEqual(box(`<svg data-x=">" ${NS} viewBox="0 0 10 50000000"/>`), [10, 50000000]);
  assert.deepEqual(box(`<!-- <svg viewBox="0 0 10 10"> --><svg ${NS} viewBox="0 0 10 50000000"/>`), [10, 50000000]);
  assert.deepEqual(box(`<svg ${NS} viewBox="-50 -10 2e+21 2e+30"/>`), [2e21, 2e30]);
  assert.match(oversize(2e21, 2e30), /too large/);
});

test("pictureOf refuses what isn't an SVG document", () => {
  assert.throws(() => pictureOf("<html></html>"), /can't be shown as an image/);
  assert.throws(() => pictureOf("not xml at all"), /can't be shown as an image/);
});

test("a decoded width or height of 0 is refused, with the note", async () => {
  assert.ok(emptyPicture({ width: 0, height: 150 }));
  assert.ok(emptyPicture({ width: 10, height: 0 }));
  assert.ok(emptyPicture(undefined));
  assert.ok(!emptyPicture({ width: 1, height: 1 }));
  const { root } = setup(answer(block()), { decodeImage: async () => ({ width: 0, height: 150 }) });
  await settle();
  assert.ok(!root.querySelector("figure"));
  assert.match(root.querySelector(".block-note").dataset.text, /can't be shown as an image/);
});

test("a picture with no box takes its decoded size", async () => {
  const { root } = setup(answer(block()), { svg: `<svg ${NS}></svg>`, decodeImage: async () => ({ width: 300, height: 150 }) });
  await settle();
  const img = root.querySelector("img");
  assert.equal(img.getAttribute("width"), "300");
  assert.equal(img.getAttribute("height"), "150");
});

test("the CSS backstop says the same maximum", async () => {
  const css = await readFile(new URL("../../../lib/samagotchi/web/public/block_renderers.css", import.meta.url), "utf8");
  assert.match(css, new RegExp(`\\.block-img\\{[^}]*max-height:${MAX_PICTURE_SIDE}px`));
  assert.match(css, new RegExp(`\\.natural \\.block-img\\{[^}]*max-width:${MAX_PICTURE_SIDE}px`));
});

test("a render that held on past the bound draws now and keeps its mark: one stall, not one per load", async (t) => {
  const storage = memoryStorage();
  const real = Date.now();
  let now = real;
  t.mock.method(Date, "now", () => now);
  const makeFrame = () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: async (_s, _t, { onStart }) => { onStart(); now += SLOW_RENDER_MS + 1; return SVG; } });
  const { root } = setup(answer(block()), { storage, makeFrame });
  await settle();
  assert.ok(figureOf(root.querySelector("pre")));
  assert.equal(storage.keys.size, 1);
});

test("a render under the bound clears its mark", async (t) => {
  const storage = memoryStorage();
  const real = Date.now();
  let now = real;
  t.mock.method(Date, "now", () => now);
  const makeFrame = () => ({ ready: Promise.resolve(), dead: () => false, drop() {}, render: async (_s, _t, { onStart }) => { onStart(); now += SLOW_RENDER_MS - 1; return SVG; } });
  setup(answer(block()), { storage, makeFrame });
  await settle();
  assert.equal(storage.keys.size, 0);
});

test("a click on the note copies its words", async () => {
  const copied = [];
  const { root } = setup(answer(block()), { throwing: new Error("Parse error"), copy: (text) => copied.push(text) });
  await settle();
  root.querySelector(".block-note").click();
  assert.deepEqual(copied, ["Couldn't draw this mermaid block: Parse error"]);
});

test("revealInHistory shows a drawn block's source when it lands in it", async () => {
  const { root } = setup(answer(block()));
  await settle();
  const pre = root.querySelector("pre");
  revealInHistory(pre.querySelector("code"));
  assert.equal(pre.hidden, false);
  assert.ok(root.querySelector("figure").classList.contains("source"));
});

test("a claim's jump to a quote in a drawn block's source shows it", async () => {
  const { root } = setup(answer(`<p>before</p>${block("graph TD\nAlpha-->Beta\n")}`));
  await settle();
  const pre = root.querySelector("pre");
  assert.equal(pre.hidden, true);
  const how = showClaim(root, { q: "Alpha-->Beta" }, { roots: ".bubble.output", win: window });
  assert.equal(how, "quote");
  assert.equal(pre.hidden, false);
});
