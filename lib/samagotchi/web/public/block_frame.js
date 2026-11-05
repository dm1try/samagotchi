// One language's renderer in a hidden sandboxed frame: a bundle's JS, whose
// input is model-written, must not reach a page that controls sessions. The
// layers and rules are docs/internals/block-renderers.md.
//
// `sandbox="allow-scripts"`, never allow-same-origin. The frame has no network
// and no cookie, so its code comes by postMessage from the page's own
// authenticated fetch and enters as `script.text` (eval doesn't work: a library's
// "use strict" keeps its global local; a syntax error doesn't throw, it reaches
// the frame's error event). The protocol, the handshake first:
//
//   frame → loaded, page → code {files}, frame → ready | failed {message}
//   page → render {id, source, theme}, frame → done {id, svg} | error {id, message}
//
// One render at a time. A timer can't fire while the renderer hangs (the frame
// shares the page's thread): block_host.js's mark is for that.
//
// A module of its own: static JS is cached at unversioned URLs.

// Same words as the spike that tested them; the page's frame-src 'none' covers
// what this doesn't (navigation).
export const FRAME_CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; form-action 'none'";
export const FRAME_TIMEOUT_MS = 15000;
// An SVG this size isn't a diagram anyone reads, and it would sit in the DOM.
export const MAX_SVG_CHARS = 8 * 1024 * 1024;

// Runs in the frame, before any bundle code. CSP doesn't stop WebRTC, so its
// constructors go (a nested srcdoc frame gets a fresh one: the residual risk,
// docs/internals/block-renderers.md).
const BOOTSTRAP = `(() => {
  delete window.RTCPeerConnection;
  delete window.webkitRTCPeerConnection;
  const send = (m) => parent.postMessage(m, "*");
  const words = (e) => String((e && e.message) || e).split("\\n")[0].slice(0, 300);
  let renderer = null;
  let loadError = null;
  window.chi = { defineRenderer(r) { renderer = r; } };
  addEventListener("error", (e) => { loadError = loadError || words(e.message || e.error); });
  async function load(files) {
    for (const code of files) {
      const tag = document.createElement("script");
      tag.text = code;
      document.head.append(tag);
      tag.remove();
      if (loadError) return send({ type: "failed", message: loadError });
    }
    if (!renderer || typeof renderer.render !== "function") return send({ type: "failed", message: "no chi.defineRenderer" });
    try { await (renderer.init && renderer.init()); } catch (e) { return send({ type: "failed", message: words(e) }); }
    send({ type: "ready" });
  }
  async function render(m) {
    try {
      const svg = await renderer.render(m.source, m.theme);
      if (typeof svg !== "string") throw new Error("the renderer returned no SVG");
      send({ type: "done", id: m.id, svg });
    } catch (e) {
      send({ type: "error", id: m.id, message: words(e) });
    }
  }
  addEventListener("message", (e) => {
    if (e.source !== parent) return;
    if (e.data.type === "code") load(e.data.files);
    else if (e.data.type === "render") render(e.data);
  });
  send({ type: "loaded" });
})();`;

export function frameSrcdoc() {
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${FRAME_CSP}"><script>${BOOTSTRAP}<\/script></head><body></body></html>`;
}

const TYPES = new Set(["loaded", "ready", "failed", "done", "error"]);

// What +event+ says, or null: only +frameWindow+'s, of a known type, and read
// as data from here on (rule 3). No other window `message` listener exists on
// this page, so this is the only receiver.
export function frameMessage(event, frameWindow) {
  if (!frameWindow || event.source !== frameWindow) return null;
  const data = event.data;
  if (!data || typeof data !== "object" || !TYPES.has(data.type)) return null;
  return data;
}

// A reason a render or load failed. +timedOut+: the page's timer fired, so the
// block is suspect (block_host.js keeps its mark); +dropped+: the page let the
// frame go, which says nothing of the block.
export class FrameError extends Error {
  constructor(message, { timedOut = false, dropped = false, load = false } = {}) {
    super(message);
    this.timedOut = timedOut;
    this.dropped = dropped;
    this.load = load;
  }
}

// @param files the renderer's file names, in load order
// @param fetchFile (file) => a promise of its text (block_host.js fetchRendererFile)
// @return {render(source, theme, {onStart}) → Promise<svg>, drop(), dead()}
export function createBlockFrame({ files, fetchFile, doc = document, win = window, timeoutMs = FRAME_TIMEOUT_MS }) {
  const iframe = doc.createElement("iframe");
  iframe.setAttribute("sandbox", "allow-scripts");
  iframe.setAttribute("aria-hidden", "true");
  iframe.setAttribute("tabindex", "-1");
  // Off-screen, not display:none: a renderer's layout measures text in it.
  iframe.style.cssText = "position:fixed;left:-10000px;top:0;width:1000px;height:800px;border:0";

  let dead = false;
  let nextId = 0;
  // What the frame is being waited for: {type?, id?, resolve, reject, timer}.
  let waiting = null;

  function die(error) {
    if (dead) return;
    dead = true;
    win.removeEventListener("message", onMessage);
    iframe.remove();
    settle((w) => w.reject(error));
  }

  function settle(answer) {
    const w = waiting;
    waiting = null;
    if (!w) return;
    clearTimeout(w.timer);
    answer(w);
  }

  // The frame's next answer, bounded.
  function answer(what, loadStage = false) {
    if (dead) return Promise.reject(new FrameError("the frame is gone", { dropped: true }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => die(new FrameError(`timed out (${what})`, { timedOut: !loadStage, load: loadStage })), timeoutMs);
      waiting = { what, resolve, reject, timer, loadStage };
    });
  }

  let loadedSeen = null;
  function onMessage(event) {
    const m = frameMessage(event, iframe.contentWindow);
    if (!m) return;
    if (m.type === "loaded") { loadedSeen?.(); return; }
    if (!waiting) return;
    if (m.type === "ready" && waiting.what === "ready") settle((w) => w.resolve());
    else if (m.type === "failed" && waiting.what === "ready") {
      settle((w) => w.reject(new FrameError(String(m.message ?? "load failed"), { load: true })));
    } else if (m.type === "done" && m.id === waiting.id) {
      if (typeof m.svg !== "string" || m.svg.length > MAX_SVG_CHARS) settle((w) => w.reject(new FrameError("the renderer's SVG is too large or not text")));
      else settle((w) => w.resolve(m.svg));
    } else if (m.type === "error" && m.id === waiting.id) {
      settle((w) => w.reject(new FrameError(String(m.message ?? "render failed"))));
    }
  }

  const loaded = new Promise((resolve) => { loadedSeen = resolve; });
  win.addEventListener("message", onMessage);
  iframe.srcdoc = frameSrcdoc();
  doc.body.append(iframe);

  async function load() {
    const texts = await Promise.all(files.map((file) => fetchFile(file)));
    const handshake = answer("load", true);
    loaded.then(() => {
      // Stop waiting on the handshake's own timer and start the code's.
      if (dead) return;
      settle((w) => w.resolve());
    });
    await handshake;
    const ready = answer("ready", true);
    iframe.contentWindow.postMessage({ type: "code", files: texts }, "*");
    await ready;
  }

  const ready = load().catch((e) => {
    const error = e instanceof FrameError ? e : new FrameError(String(e?.message || e), { load: true });
    die(error);
    throw error;
  });
  // One render at a time, whatever the last one came to.
  let queue = ready.catch(() => {});

  function render(source, theme, { onStart = () => {} } = {}) {
    const run = async () => {
      await ready;
      if (dead) throw new FrameError("the frame is gone", { dropped: true });
      onStart();
      const id = ++nextId;
      const done = answer(`render ${id}`);
      waiting.id = id;
      iframe.contentWindow.postMessage({ type: "render", id, source, theme }, "*");
      return done;
    };
    const result = queue.then(run);
    queue = result.catch(() => {});
    return result;
  }

  return {
    ready,
    render,
    dead: () => dead,
    drop: () => die(new FrameError("dropped", { dropped: true })),
  };
}
