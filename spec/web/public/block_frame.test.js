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
  const parent = { postMessage: (m) => sent.push(m) };
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
  await assert.rejects(frame.render("bad", {}), /nope/);
  assert.equal(frame.dead(), false, "a renderer's error isn't the frame's end");
  assert.equal(await frame.render("C", {}), "<svg>C</svg>");
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
