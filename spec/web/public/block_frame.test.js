import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { createBlockFrame, FRAME_CSP, frameMessage, frameSrcdoc, MAX_SVG_CHARS } from "../../../lib/samagotchi/web/public/block_frame.js";

function fakeFrameEnv() {
  const posted = [];
  const contentWindow = { postMessage: (m) => { posted.push(m); answer(m); } };
  const iframe = {
    attrs: {}, style: {}, removed: false, contentWindow,
    setAttribute(k, v) { this.attrs[k] = v; },
    remove() { this.removed = true; },
  };
  let listener = null;
  const win = {
    addEventListener: (_type, fn) => { listener = fn; },
    removeEventListener: () => { listener = null; },
  };
  const doc = { createElement: () => iframe, body: { append: () => {} } };
  let answer = () => {};
  return {
    iframe, posted, win, doc,
    onPost: (fn) => { answer = fn; },
    say: (data, source = contentWindow) => listener?.({ source, data }),
    listening: () => listener !== null,
  };
}

test("the frame is sandboxed with scripts only", () => {
  const env = fakeFrameEnv();
  const frame = createBlockFrame({ files: [], fetchFile: async () => "", doc: env.doc, win: env.win, timeoutMs: 1000 });
  assert.equal(env.iframe.attrs.sandbox, "allow-scripts");
  assert.equal(env.iframe.attrs["aria-hidden"], "true");
  assert.equal(env.iframe.attrs.tabindex, "-1");
  frame.ready.catch(() => {});
  frame.drop();
});

test("the srcdoc says the CSP before any script", () => {
  const doc = frameSrcdoc();
  assert.ok(FRAME_CSP.startsWith("default-src 'none'"));
  assert.ok(doc.includes(`content="${FRAME_CSP}"`));
  assert.ok(doc.indexOf(FRAME_CSP) < doc.indexOf("<script>"));
});

// The bootstrap itself, run: a fake window for what it touches.
function runBootstrap() {
  const listeners = {};
  const sent = [];
  // As a real post: a structured clone, which throws on what can't be cloned.
  const parent = { postMessage: (m) => sent.push(structuredClone(m)) };
  const appended = [];
  const window = { RTCPeerConnection: class {}, webkitRTCPeerConnection: class {} };
  const context = vm.createContext({
    window, parent, addEventListener: (type, fn) => { listeners[type] = fn; },
    document: { createElement: () => ({ remove() {} }), head: { append: (tag) => { appended.push(tag.text); } } },
    String, Error, Promise, setTimeout,
  });
  const code = /<script>([^]*)<\/script>/.exec(frameSrcdoc())[1];
  vm.runInContext(code, context);
  return { window, parent, listeners, sent, appended };
}

test("the bootstrap takes the WebRTC constructors away, and says loaded", () => {
  const { window, sent } = runBootstrap();
  assert.equal("RTCPeerConnection" in window, false);
  assert.equal("webkitRTCPeerConnection" in window, false);
  assert.deepEqual(sent.map((m) => m.type), ["loaded"]);
});

test("the bootstrap answers only its parent", async () => {
  const { listeners, parent, appended, sent } = runBootstrap();
  listeners.message({ source: {}, data: { type: "code", files: ["evil()"] } });
  listeners.message({ source: null, data: { type: "render", id: 1, source: "x" } });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(appended, []);
  assert.deepEqual(sent.map((m) => m.type), ["loaded"]);
  listeners.message({ source: parent, data: { type: "code", files: ["ok()"] } });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(appended, ["ok()"]);
});

// The bootstrap with +render+ as its renderer, loaded: the frame's answer to one render.
async function bootRender(render) {
  const boot = runBootstrap();
  boot.window.chi.defineRenderer({ render });
  boot.listeners.message({ source: boot.parent, data: { type: "code", files: [] } });
  await new Promise((r) => setTimeout(r, 0));
  boot.listeners.message({ source: boot.parent, data: { type: "render", id: 7, source: "s", theme: {} } });
  await new Promise((r) => setTimeout(r, 0));
  return { features: boot.window.chi.features, answer: boot.sent.at(-1) };
}

test("the bootstrap says it takes regions", async () => {
  const { features } = await bootRender(() => "<svg/>");
  assert.equal(features.regions, true);
});

test("a string is the SVG, with no regions", async () => {
  const { answer } = await bootRender(() => "<svg/>");
  assert.deepEqual(answer, { type: "done", id: 7, svg: "<svg/>" });
});

test("an object gives its svg and its regions", async () => {
  const regions = [{ kind: "node", id: "A", label: "a", box: [0, 0, 0.5, 0.5] }];
  const { answer } = await bootRender(() => ({ svg: "<svg/>", regions }));
  assert.deepEqual(answer, { type: "done", id: 7, svg: "<svg/>", regions });
});

test("an object without a string svg is the bundle's bug: an error marked bundle; a throw stays the renderer's", async () => {
  for (const out of [{ regions: [] }, { svg: 5 }, { get svg() { throw new Error("x"); } }]) {
    const { answer } = await bootRender(() => out);
    assert.deepEqual(answer, { type: "error", id: 7, message: "the renderer returned no SVG", bundle: true });
  }
  const thrown = await bootRender(() => { throw new Error("Parse error on line 2"); });
  assert.deepEqual(thrown.answer, { type: "error", id: 7, message: "Parse error on line 2" });
  const none = await bootRender(() => undefined);
  assert.deepEqual(none.answer, { type: "error", id: 7, message: "the renderer returned no SVG" }, "no object at all: as before");
});

test("601 regions, or regions that aren't an array: done without them", async () => {
  const many = Array.from({ length: 601 }, () => ({ kind: "node" }));
  for (const regions of [many, { length: 1 }, "x"]) {
    const { answer } = await bootRender(() => ({ svg: "<svg/>", regions }));
    assert.deepEqual(answer, { type: "done", id: 7, svg: "<svg/>" });
  }
});

test("uncloneable regions (a function, a proxy that throws): done without them", async () => {
  const trap = new Proxy([], { get(t, k) { if (k === "length") return 1; if (k === "0") throw new Error("trap"); return Reflect.get(t, k); } });
  for (const regions of [[{ kind: "node", f: () => 1 }], trap]) {
    const { answer } = await bootRender(() => ({ svg: "<svg/>", regions }));
    assert.deepEqual(answer, { type: "done", id: 7, svg: "<svg/>" });
  }
});

test("frameMessage takes only the frame's own messages of known types", () => {
  const frameWindow = {};
  assert.deepEqual(frameMessage({ source: frameWindow, data: { type: "done", id: 1, svg: "x" } }, frameWindow), { type: "done", id: 1, svg: "x" });
  assert.equal(frameMessage({ source: {}, data: { type: "done" } }, frameWindow), null);
  assert.equal(frameMessage({ source: null, data: { type: "done" } }, null), null);
  assert.equal(frameMessage({ source: frameWindow, data: { type: "navigate", url: "x" } }, frameWindow), null);
  assert.equal(frameMessage({ source: frameWindow, data: "done" }, frameWindow), null);
  assert.equal(frameMessage({ source: frameWindow, data: null }, frameWindow), null);
});

function started({ timeoutMs = 1000, files = ["a.js", "b.js"], fetchFile = async (f) => `code of ${f}` } = {}) {
  const env = fakeFrameEnv();
  env.onPost((m) => {
    if (m.type === "code") queueMicrotask(() => env.say({ type: "ready" }));
    if (m.type === "render") queueMicrotask(() => env.say(m.source === "bad" ? { type: "error", id: m.id, message: "nope" } : { type: "done", id: m.id, svg: `<svg>${m.source}</svg>` }));
  });
  const frame = createBlockFrame({ files, fetchFile, doc: env.doc, win: env.win, timeoutMs });
  return { env, frame };
}

test("the handshake: loaded, then the code in order, then ready; then renders answer by id", async () => {
  const { env, frame } = started();
  env.say({ type: "loaded" });
  await frame.ready;
  assert.deepEqual(env.posted[0], { type: "code", files: ["code of a.js", "code of b.js"] });
  let started_ = 0;
  const svg = await frame.render("A", { name: "dark" }, { onStart: () => { started_ += 1; } });
  assert.equal(svg, "<svg>A</svg>");
  assert.equal(started_, 1);
  await assert.rejects(frame.render("bad", {}), (e) => /nope/.test(e.message) && e.renderer === true && !e.load);
  assert.equal(frame.dead(), false, "a renderer's error isn't the frame's end");
  assert.equal(await frame.render("C", {}), "<svg>C</svg>");
  frame.drop();
});

test("draw resolves the SVG with its regions (none yet); render is its SVG alone", async () => {
  const { env, frame } = started();
  env.say({ type: "loaded" });
  await frame.ready;
  assert.deepEqual(await frame.draw("A", {}), { svg: "<svg>A</svg>", regions: null });
  assert.equal(await frame.render("B", {}), "<svg>B</svg>");
  frame.drop();
});

test("draw resolves the frame's regions raw; a bundle error isn't the renderer's", async () => {
  const env = fakeFrameEnv();
  env.onPost((m) => {
    if (m.type === "code") queueMicrotask(() => env.say({ type: "ready" }));
    if (m.type === "render" && m.source === "R") queueMicrotask(() => env.say({ type: "done", id: m.id, svg: "<svg/>", regions: [1, 2] }));
    if (m.type === "render" && m.source === "B") queueMicrotask(() => env.say({ type: "error", id: m.id, message: "the renderer returned no SVG", bundle: true }));
  });
  const frame = createBlockFrame({ files: [], fetchFile: async () => "", doc: env.doc, win: env.win, timeoutMs: 1000 });
  env.say({ type: "loaded" });
  await frame.ready;
  assert.deepEqual(await frame.draw("R", {}), { svg: "<svg/>", regions: [1, 2] });
  await assert.rejects(frame.draw("B", {}), (e) => /no SVG/.test(e.message) && e.renderer === false);
  frame.drop();
});

test("renders run one at a time, in order", async () => {
  const { env, frame } = started();
  env.say({ type: "loaded" });
  const order = [];
  const results = await Promise.all(["1", "2", "3"].map((s) => frame.render(s, {}, { onStart: () => order.push(s) })));
  assert.deepEqual(order, ["1", "2", "3"]);
  assert.deepEqual(results, ["<svg>1</svg>", "<svg>2</svg>", "<svg>3</svg>"]);
  frame.drop();
});

test("a message from elsewhere answers nothing", async () => {
  const { env, frame } = started();
  env.onPost(() => {});
  env.say({ type: "loaded" });
  await new Promise((r) => setTimeout(r, 0));
  env.say({ type: "ready" }, {}); // another window
  let settled = false;
  frame.ready.then(() => { settled = true; }, () => { settled = true; });
  for (let i = 0; i < 5; i++) await Promise.resolve(); // let any settle callback run
  assert.equal(settled, false);
  env.say({ type: "ready" }); // the frame itself: the positive signal that ready can settle
  await frame.ready;
  assert.equal(settled, true);
  frame.drop();
});

test("a failed load rejects with its words and removes the frame", async () => {
  const env = fakeFrameEnv();
  env.onPost((m) => { if (m.type === "code") queueMicrotask(() => env.say({ type: "failed", message: "SyntaxError: x" })); });
  const frame = createBlockFrame({ files: ["a.js"], fetchFile: async () => "x", doc: env.doc, win: env.win });
  env.say({ type: "loaded" });
  await assert.rejects(frame.ready, (e) => e.load === true && /SyntaxError/.test(e.message));
  assert.equal(frame.dead(), true);
  assert.equal(env.iframe.removed, true);
  assert.equal(env.listening(), false);
  await assert.rejects(frame.render("A", {}));
});

test("a file the page can't fetch is a failed load", async () => {
  const { frame } = started({ fetchFile: async () => { throw new Error("answered 409"); } });
  await assert.rejects(frame.ready, /answered 409/);
  assert.equal(frame.dead(), true);
});

// Browser fetch has no timeout of its own: a stalled renderer file (a proxy or a
// tunnel holding the request) must not leave ready pending for good.
test("a fetch past its timeout is a failed load, and drops the frame", { timeout: 2000 }, async () => {
  const { env, frame } = started({ timeoutMs: 10, fetchFile: () => new Promise(() => {}) });
  env.say({ type: "loaded" });
  await assert.rejects(frame.ready, (e) => e.load === true && e.timedOut === false && /timed out \(fetch\)/.test(e.message));
  assert.equal(frame.dead(), true);
  assert.equal(env.iframe.removed, true);
  assert.equal(env.posted.length, 0, "no code is sent");
});

test("drop during the fetch rejects ready as dropped", { timeout: 2000 }, async () => {
  const { env, frame } = started({ fetchFile: () => new Promise(() => {}) });
  env.say({ type: "loaded" });
  const pending = frame.render("A", {});
  await new Promise((r) => setTimeout(r, 0));
  frame.drop();
  await assert.rejects(frame.ready, (e) => e.dropped === true);
  await assert.rejects(pending, (e) => e.dropped === true);
  assert.equal(env.listening(), false);
});

test("a fetch that ends after the frame is dropped sends no code", async () => {
  let finish;
  const { env, frame } = started({ fetchFile: () => new Promise((r) => { finish = r; }) });
  env.say({ type: "loaded" });
  await new Promise((r) => setTimeout(r, 0));
  frame.drop();
  finish("late");
  await assert.rejects(frame.ready, (e) => e.dropped === true);
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(env.posted.length, 0);
});

// Its own bound: without a timeout firing, this test would otherwise wait forever.
test("a render past its timeout says so, and drops the frame", { timeout: 2000 }, async () => {
  const { env, frame } = started({ timeoutMs: 10 });
  env.say({ type: "loaded" });
  await frame.ready;
  env.onPost(() => {});
  await assert.rejects(frame.render("A", {}), (e) => e.timedOut === true);
  assert.equal(frame.dead(), true);
  assert.equal(env.iframe.removed, true);
});

test("drop rejects what's waiting as dropped and removes the frame", async () => {
  const { env, frame } = started();
  env.say({ type: "loaded" });
  await frame.ready;
  env.onPost(() => {});
  const pending = frame.render("A", {});
  await new Promise((r) => setTimeout(r, 0));
  frame.drop();
  await assert.rejects(pending, (e) => e.dropped === true);
  assert.equal(env.iframe.removed, true);
  assert.equal(env.listening(), false);
});

test("an oversize answer is refused", async () => {
  const { env, frame } = started();
  env.say({ type: "loaded" });
  await frame.ready;
  env.onPost((m) => queueMicrotask(() => env.say({ type: "done", id: m.id, svg: "x".repeat(MAX_SVG_CHARS + 1) })));
  await assert.rejects(frame.render("A", {}), /too large/);
  frame.drop();
});
