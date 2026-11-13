// Draws a bundle's fenced blocks in the page (docs/internals/block-renderers.md),
// in a hidden frame per language. Finding and watching the blocks is
// block_watch.js's; this is its frame drawer, after any core drawers.
//
// The DOM is the state: a <figure class="block-drawn"> right before the <pre>
// (block_source.js) says it is drawn, so a Revise clone needs nothing, and
// data-block-failed on the <pre> says it isn't to be tried again. The figure
// holds an <img src="data:..."> only: the frame's output is never innerHTML, and
// never a blob: (a blob has this page's origin, and the browser's own "Open
// Image in New Tab" navigates to it).
//
// A module of its own: static JS is cached at unversioned URLs.

import { html, render as litRender } from "./vendor/lit-html.js";
import { createBlockFrame, FRAME_TIMEOUT_MS } from "./block_frame.js";
import { DRAWN, figureOf, setSourceShown } from "./block_source.js";
import { createBlockWatch, failBlock, holdingView } from "./block_watch.js";
import { copyText } from "./copy.js";

// MessageDisplay::MAX_RENDER_BYTES's number: a source over it stays source.
export const MAX_SOURCE_BYTES = 64 * 1024;
export const CACHE_SIZE = 200;
export const MARK_PREFIX = "chi_block_rendering:";
const MAX_RETRIES = 5;
// The biggest picture a page shows, whatever the renderer: a model-written
// directive can ask Mermaid for an SVG tens of millions of px tall, which breaks
// the session's scrolling. Over it the block stays source. The real diagrams of
// eval 0012 reach about 2500 px a side and 3.5M px: docs/internals/block-renderers.md.
export const MAX_PICTURE_SIDE = 50000;
export const MAX_PICTURE_PIXELS = 100_000_000;
export const DECODE_TIMEOUT_MS = 15000;
// A render that held on this long keeps its mark: it stalls the page once, not on
// every load. Real Mermaid's worst is about 1 s.
export const SLOW_RENDER_MS = 10000;
const NOT_AN_IMAGE = "the renderer's SVG can't be shown as an image";
// A very wide diagram scaled to the column would be a sliver: it stays at least
// this tall and scrolls sideways instead.
const MIN_SHOWN_HEIGHT = 120;

// The zoom button's words: the picture fitted to the column, or at its natural size.
const ZOOM_IN = "Show at full size";
const ZOOM_OUT = "Fit to the column";

const ZOOM_ICON = html`<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="7" cy="7" r="4.25" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="m10.2 10.2 3.3 3.3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`;
const ICON = html`<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M5.5 4 2 8l3.5 4M10.5 4 14 8l-3.5 4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

// The picture's URL and size. The XML parser reads the root, as the image will: a
// regex over model-influenced XML finds the wrong box or none (an exponent, a comment
// holding "<svg", a ">" in an attribute, an entity, a prefix). width and height come
// from the viewBox, as Mermaid's width="100%" gives an <img> a wrong natural size. No
// usable box: the size is what it decodes to (block_host's draw). Only ever a
// data: URL (rule 2).
// @throws Error it isn't an SVG document
export function pictureOf(svg, win = window) {
  const parsed = new win.DOMParser().parseFromString(svg, "image/svg+xml");
  const root = parsed.documentElement;
  if (root?.localName !== "svg" || parsed.querySelector("parsererror")) throw new Error(NOT_AN_IMAGE);
  const box = String(root.getAttribute("viewBox") ?? "").trim().split(/[\s,]+/).map(Number);
  const sized = box.length === 4 && box[2] > 0 && box[3] > 0;
  if (sized) {
    root.setAttribute("width", box[2]);
    root.setAttribute("height", box[3]);
  }
  const text = sized ? new win.XMLSerializer().serializeToString(parsed) : svg;
  return { url: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(text)}`, width: sized ? box[2] : null, height: sized ? box[3] : null };
}

// Why a picture of this size isn't shown, or null.
export function oversize(width, height) {
  if (!width || !height) return null; // no box: its decoded size is checked
  if (width <= MAX_PICTURE_SIDE && height <= MAX_PICTURE_SIDE && width * height <= MAX_PICTURE_PIXELS) return null;
  return `the picture would be ${Math.round(width)} x ${Math.round(height)} px, too large to show`;
}

// The width that keeps a picture at least MIN_SHOWN_HEIGHT tall, never past its
// natural size; null when it needs none of that.
export function minShownWidth(width, height) {
  if (!width || !height) return null;
  return Math.min(width, Math.ceil((width * MIN_SHOWN_HEIGHT) / height));
}

// A decoded size that isn't a picture: nothing to see, or a size the browser
// couldn't work out (WebKit's 0 x 150 for a viewBox it can't hold).
export function emptyPicture(natural) {
  return !(natural?.width > 0 && natural?.height > 0);
}

// A short name for +source+ in sessionStorage; a collision only leaves a block
// as source. No crypto.subtle: it's undefined on a plain-http LAN address.
export function sourceHash(source) {
  let h = 0x811c9dc5;
  for (let i = 0; i < source.length; i++) h = Math.imul(h ^ source.charCodeAt(i), 0x01000193);
  return `${(h >>> 0).toString(36)}.${source.length}`;
}

// A renderer's file by the page's own fetch (the frame has no network). Not
// data.js api: that's JSON. The content type keeps a proxy's sign-in HTML from
// being passed in as code.
export async function fetchRendererFile(bundle, file) {
  const res = await fetch(`/api/block_renderers/${encodeURIComponent(bundle)}/${encodeURIComponent(file)}`, { headers: { Accept: "text/javascript" } });
  if (!res.ok) throw new Error(`the renderer's ${file} answered ${res.status}`);
  if (!/javascript/i.test(res.headers.get("content-type") || "")) throw new Error(`the renderer's ${file} isn't a script`);
  return res.text();
}

export async function fetchRendererList() {
  const res = await fetch("/api/block_renderers", { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`block renderers answered ${res.status}`);
  return (await res.json()).renderers;
}

// The page's tokens as a small generic object; mapping it to a library is the
// bundle's job.
export function currentTheme(doc = document, win = window) {
  const style = win.getComputedStyle(doc.documentElement);
  const token = (name) => style.getPropertyValue(name).trim();
  return {
    name: win.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light",
    bg: token("--bg"), panel: token("--bg-panel"), text: token("--text"), muted: token("--text-3"),
    border: token("--border-strong"), accent: token("--accent"), font: win.getComputedStyle(doc.body).fontFamily,
  };
}

function guardedStorage(get) {
  const use = (fn, fallback) => { try { return fn(get()); } catch (_) { return fallback; } };
  return {
    has: (key) => use((s) => s.getItem(key) !== null, false),
    set: (key) => use((s) => s.setItem(key, "1")),
    remove: (key) => use((s) => s.removeItem(key)),
  };
}


// The drawer of a bundle's renderers (block_watch.js has the contract): one
// frame per language, waiting for /api/block_renderers to say who draws what.
// @param roots the turn roots, for the view held and the zoom's listeners
// The rest are createBlockHost's.
export function createFrameDrawer({
  roots, listRenderers = fetchRendererList, fetchFile = fetchRendererFile, makeFrame = createBlockFrame,
  decodeImage = async (url) => { const img = new win.Image(); img.src = url; await img.decode(); return { width: img.naturalWidth, height: img.naturalHeight }; },
  decodeTimeoutMs = DECODE_TIMEOUT_MS, theme = currentTheme,
  doc = document, win = window, storage = guardedStorage(() => globalThis.sessionStorage),
}) {
  const cache = new Map();
  const frames = new Map();
  // A language whose renderer didn't load, and why: until the session changes,
  // its blocks don't fetch it again one by one.
  const broken = new Map();
  // The marks of the renders running now: mark => when it started. Such a mark isn't
  // a leftover from an earlier load.
  const inFlight = new Map();
  // The pictures on their way, by cache key: a bubble rewritten or cloned during a
  // render has its blocks wait for that one, and each draws into whichever is connected.
  const coming = new Map();
  const retries = new WeakMap();
  // What needsDraw checked, so draw draws that: pre => {lang, source, renderer}.
  const checked = new WeakMap();
  let list = null;
  let listLoad = null;

  // The list once loaded; till then a promise of it, asked for once per page load.
  function renderers() {
    if (list) return list;
    listLoad ??= listRenderers().then(
      (got) => { list = new Map((got || []).map((r) => [r.lang, r])); return list; },
      () => { list = new Map(); return list; }, // a failed list: no drawing
    );
    return listLoad;
  }

  function dropFrames() {
    for (const frame of frames.values()) frame.drop();
    frames.clear();
    broken.clear();
  }

  function frameFor(lang, renderer) {
    let frame = frames.get(lang);
    if (frame && !frame.dead()) return frame;
    frame = makeFrame({ files: renderer.files, fetchFile: (file) => fetchFile(renderer.bundle, file) });
    frame.ready.catch((e) => { if (!e?.dropped) broken.set(lang, e?.message || "its renderer didn't load"); });
    frames.set(lang, frame);
    return frame;
  }

  function remember(key, picture) {
    cache.delete(key);
    cache.set(key, picture);
    if (cache.size > CACHE_SIZE) cache.delete(cache.keys().next().value);
  }

  const cacheKey = (lang, themeName, source) => `${lang}\u0000${themeName}\u0000${source}`;
  const markKey = (lang, source) => `${MARK_PREFIX}${lang}:${sourceHash(source)}`;
  const langOf = (pre) => pre.getAttribute("data-lang");

  function setMark(mark) {
    storage.set(mark);
    inFlight.set(mark, Date.now());
  }

  function clearMark(mark) {
    storage.remove(mark);
    inFlight.delete(mark);
  }

  // A reload during a render isn't a hang: its mark goes. A page truly hung never
  // runs this, and one that was stuck past the frame's timeout has shown it is
  // suspect, so that mark stays.
  win.addEventListener?.("pagehide", () => {
    const now = Date.now();
    for (const [mark, started] of inFlight) if (now - started < FRAME_TIMEOUT_MS) clearMark(mark);
  });

  // The decoded image, bounded: a browser can sit on a vast SVG without ending.
  function decoded(url) {
    let timer;
    const bound = new Promise((_, reject) => {
      timer = setTimeout(() => reject(Object.assign(new Error("the picture took too long to show"), { timedOut: true })), decodeTimeoutMs);
    });
    const image = Promise.resolve().then(() => decodeImage(url)).catch(() => {
      throw new Error(NOT_AN_IMAGE);
    });
    return Promise.race([image, bound]).finally(() => clearTimeout(timer));
  }

  // The picture's name says where its words are: the source <pre> is hidden, so a
  // screen reader reaches it through the toggle. The zoom is a button too, for the
  // keyboard (a click on the picture does the same); it shows on keyboard focus only.
  function makeFigure(picture, themeName, lang) {
    const figure = doc.createElement("figure");
    figure.className = DRAWN;
    figure.dataset.theme = themeName;
    const scroll = doc.createElement("div");
    scroll.className = "block-scroll";
    const img = doc.createElement("img");
    img.className = "block-img";
    img.alt = `${lang} diagram, its source under the Show the source button`;
    showPicture(img, picture);
    scroll.append(img);
    const zoom = button("block-zoom", ZOOM_ICON);
    const toggle = button("block-toggle", ICON);
    figure.append(scroll, zoom, toggle);
    setZoomed(figure, false);
    return figure;
  }

  function button(className, icon) {
    const el = doc.createElement("button");
    el.type = "button";
    el.className = className;
    litRender(icon, el);
    return el;
  }

  function setZoomed(figure, on) {
    figure.classList.toggle("natural", on);
    const zoom = figure.querySelector(":scope > .block-zoom");
    if (!zoom) return;
    zoom.setAttribute("aria-pressed", on ? "true" : "false");
    zoom.setAttribute("aria-label", on ? ZOOM_OUT : ZOOM_IN);
    zoom.title = on ? ZOOM_OUT : ZOOM_IN;
  }

  function showPicture(img, { url, width, height }) {
    if (width && height) {
      img.setAttribute("width", width);
      img.setAttribute("height", height);
      img.style.minWidth = `${minShownWidth(width, height)}px`;
    }
    img.src = url;
  }

  function place(pre, picture, themeName, lang) {
    if (!pre.isConnected) return;
    const drawn = figureOf(pre);
    if (drawn) {
      drawn.dataset.theme = themeName;
      showPicture(drawn.querySelector(".block-img"), picture);
      return;
    }
    const figure = makeFigure(picture, themeName, lang);
    holdingView(pre, roots, () => {
      pre.before(figure);
      setSourceShown(figure, pre, false);
    }, () => figure.getBoundingClientRect().bottom, win);
  }

  function pictureFor(key, lang, source, renderer, now) {
    let picture = coming.get(key);
    if (!picture) {
      picture = rendered(key, lang, source, renderer, now).finally(() => coming.delete(key));
      coming.set(key, picture);
    }
    return picture;
  }

  // The size that counts is what shows: from the root's box before the decode (a
  // vast one needn't be tried), and what it decoded to in any case.
  async function rendered(key, lang, source, renderer, now) {
    const mark = markKey(lang, source);
    try {
      const svg = await frameFor(lang, renderer).render(source, now, { onStart: () => setMark(mark) });
      const started = inFlight.get(mark);
      const picture = pictureOf(svg, win);
      const tooLarge = oversize(picture.width, picture.height);
      if (tooLarge) throw new Error(tooLarge);
      const natural = await decoded(picture.url);
      if (emptyPicture(natural)) throw new Error(NOT_AN_IMAGE);
      const tooLargeShown = oversize(natural.width, natural.height);
      if (tooLargeShown) throw new Error(tooLargeShown);
      if (Date.now() - started > SLOW_RENDER_MS) inFlight.delete(mark);
      else clearMark(mark);
      const shown = picture.width ? picture : { ...picture, width: natural.width, height: natural.height };
      remember(key, shown);
      return shown;
    } catch (e) {
      // A timeout's mark stays: the block is suspect on the next load too.
      if (e?.timedOut) inFlight.delete(mark);
      else clearMark(mark);
      throw e;
    }
  }

  // A claimed language has a renderer: the list is loaded by then.
  function needsDraw(pre, figure) {
    const lang = langOf(pre);
    const source = pre.textContent;
    const now = theme(doc, win);
    if (figure && figure.dataset.theme === now.name) return false;
    const hit = cache.get(cacheKey(lang, now.name, source));
    if (hit) { place(pre, hit, now.name, lang); return false; } // no flash: this frame
    if (!figure) {
      if (new TextEncoder().encode(source).length > MAX_SOURCE_BYTES) { failBlock(pre, lang, "it is over 64 KB"); return false; }
      const mark = markKey(lang, source);
      if (storage.has(mark) && !inFlight.has(mark)) { failBlock(pre, lang, "it hung or took too long the last time"); return false; }
    }
    checked.set(pre, { lang, source, renderer: list.get(lang) });
    return true;
  }

  async function draw(pre, { reconsider }) {
    const { lang, source, renderer } = checked.get(pre);
    const now = theme(doc, win);
    const key = cacheKey(lang, now.name, source);
    const hit = cache.get(key);
    if (hit) { place(pre, hit, now.name, lang); return; }
    if (broken.has(lang)) { failBlock(pre, lang, broken.get(lang)); return; }
    let retry = false;
    try {
      place(pre, await pictureFor(key, lang, source, renderer, now), now.name, lang);
    } catch (e) {
      // A redraw that failed keeps the picture it has.
      if (!e?.dropped && !figureOf(pre)) failBlock(pre, lang, e?.message);
      retry = !!e?.dropped;
    }
    // Queued behind a frame that died (another block's timeout): a new frame's
    // turn. A session switch's frames go with their blocks, which aren't connected.
    // Each such death uses up one block, so this ends; the cap is for what would
    // otherwise spin the page if that ever stopped being true.
    if (!retry) return;
    const tries = (retries.get(pre) || 0) + 1;
    retries.set(pre, tries);
    if (tries <= MAX_RETRIES) reconsider(pre);
    else failBlock(pre, lang, "its renderer keeps stopping");
  }

  for (const root of roots) {
    root.addEventListener("mousedown", (e) => {
      if (e.target.closest?.(".block-zoom")) e.preventDefault();
    });
    // Delegated, so a Revise clone's work too.
    root.addEventListener("click", (e) => {
      if (!e.target.closest?.(".block-zoom, .block-img")) return;
      const figure = e.target.closest(`.${DRAWN}`);
      setZoomed(figure, !figure.classList.contains("natural"));
    });
  }

  return {
    claims(lang) {
      const known = renderers();
      return known.then ? known.then((got) => got.has(lang)) : known.has(lang);
    },
    needsDraw,
    draw,
    sessionChanged: dropFrames,
    dropFrames,
  };
}

// @param roots the turn roots (app.js turnRoots())
// @param sessionId () => the open session's id: the frames go on a change, to
//   limit what they hold (docs/internals/block-renderers.md, residual risk)
// @param drawers core drawers, asked before the bundle renderers
// The rest are seams for the specs.
// +renderers+: false for a viewer without the bundles' renderers (viewer.js):
// the core +drawers+ only, and GET /api/block_renderers is never asked.
export function createBlockHost({ roots, sessionId, drawers = [], copy = copyText, watch = null, win = window, renderers = true,
  ...frameOpts }) {
  const frames = renderers ? createFrameDrawer({ roots, win, ...frameOpts }) : null;
  const watcher = createBlockWatch({ roots, sessionId, drawers: frames ? [...drawers, frames] : drawers, watch, copy, win });
  // A system theme change redraws through the figure (needsDraw's theme check).
  win.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
    for (const root of roots) watcher.scan(root);
  });
  return { scan: watcher.scan, dropFrames: frames ? frames.dropFrames : () => {} };
}
