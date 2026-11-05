// Draws a bundle's fenced blocks in the page (docs/internals/block-renderers.md).
// One observer per turn root, filtered to TEXTS, as copy.js and answer_fold.js:
// every path that fills a root (a reload, a session switch, a turn's end, an
// answer_display, Revise's clones, a step's swap) arrives the same way, and
// cards, the asking slot and question replies are never touched.
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
import { copyText } from "./copy.js";
import { keepFollowing, shouldFollowScroll } from "./scroll.js";
import { TEXTS } from "./text_roots.js";

const BLOCKS = "pre[data-lang]";
// MessageDisplay::MAX_RENDER_BYTES's number: a source over it stays source.
export const MAX_SOURCE_BYTES = 64 * 1024;
export const CACHE_SIZE = 200;
export const MARK_PREFIX = "chi_block_rendering:";
const IO_MARGIN = "600px 0px";
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

// The nearest scroller holding +el+, +root+ at the latest. IntersectionObserver
// needs it named: with root:null a rootMargin doesn't pass an overflow:auto
// between, so a block just under #history's fold wouldn't count.
function scrollerOf(el, root, win) {
  for (let at = el.parentElement; at && at !== root; at = at.parentElement) {
    const { overflowY } = win.getComputedStyle(at);
    if (overflowY === "auto" || overflowY === "scroll") return at;
  }
  return root;
}

// One IntersectionObserver per scroller. +el+ moved to another scroller (the
// stage's hand-off to the history) moves with it.
function ioWatcher(win) {
  const observers = new Map();
  const watched = new WeakMap();
  return (el, scroller, onNear) => {
    let io = observers.get(scroller);
    if (!io) {
      io = new win.IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          io.unobserve(entry.target);
          const near = watched.get(entry.target);
          watched.delete(entry.target);
          near?.onNear();
        }
      }, { root: scroller, rootMargin: IO_MARGIN });
      observers.set(scroller, io);
    }
    const before = watched.get(el);
    if (before && before.io !== io) before.io.unobserve(el);
    watched.set(el, { io, onNear });
    io.observe(el);
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

// @param roots the turn roots (app.js turnRoots())
// @param sessionId () => the open session's id: the frames go on a change, to
//   limit what they hold (docs/internals/block-renderers.md, residual risk)
// The rest are seams for the specs.
export function createBlockHost({
  roots, sessionId, listRenderers = fetchRendererList, fetchFile = fetchRendererFile, makeFrame = createBlockFrame,
  decodeImage = async (url) => { const img = new win.Image(); img.src = url; await img.decode(); return { width: img.naturalWidth, height: img.naturalHeight }; },
  decodeTimeoutMs = DECODE_TIMEOUT_MS, theme = currentTheme, copy = copyText,
  watch = null, doc = document, win = window, storage = guardedStorage(() => globalThis.sessionStorage),
}) {
  const near = watch || ioWatcher(win);
  const cache = new Map();
  const frames = new Map();
  // A language whose renderer didn't load, and why: until the session changes,
  // its blocks don't fetch it again one by one.
  const broken = new Map();
  // Blocks with a draw on its way (not a drawn state: that is the figure): pre =>
  // {target, scroller, start, drawing}. Until it starts, a block whose scroller
  // changed (the stage's hand-off to the history) gets watched there.
  const waiting = new WeakMap();
  // The marks of the renders running now: mark => when it started. Such a mark isn't
  // a leftover from an earlier load.
  const inFlight = new Map();
  // The pictures on their way, by cache key: a bubble rewritten or cloned during a
  // render has its blocks wait for that one, and each draws into whichever is connected.
  const coming = new Map();
  const retries = new WeakMap();
  let list = null;
  let listLoad = null;
  let session = sessionId();

  function withRenderers(fn) {
    if (list) { fn(list); return; }
    listLoad ??= listRenderers().then(
      (renderers) => { list = new Map((renderers || []).map((r) => [r.lang, r])); return list; },
      () => { list = new Map(); return list; }, // a failed list: no drawing
    );
    listLoad.then(fn);
  }

  function dropFrames() {
    for (const frame of frames.values()) frame.drop();
    frames.clear();
    broken.clear();
  }

  function noticeSession() {
    const now = sessionId();
    if (now === session) return;
    session = now;
    dropFrames();
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

  function rootOf(el) {
    return roots.find((root) => root.contains(el)) || roots[0];
  }

  // +mutate+ with the view held: a viewer at the bottom stays there, and a
  // block above a reader's view keeps what they read where it is. Browsers that
  // anchor scrolling have done it by the second read, and there is nothing left.
  function holdingView(pre, mutate, bottomOf) {
    const scroller = scrollerOf(pre, rootOf(pre), win);
    if (shouldFollowScroll(scroller)) return keepFollowing(scroller, mutate);
    const before = pre.getBoundingClientRect().bottom;
    if (before > scroller.getBoundingClientRect().top) return mutate();
    const result = mutate();
    const after = bottomOf();
    if (after !== before) scroller.scrollTop += after - before;
    return result;
  }

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

  function makeFigure(picture, themeName, lang) {
    const figure = doc.createElement("figure");
    figure.className = DRAWN;
    figure.dataset.theme = themeName;
    const scroll = doc.createElement("div");
    scroll.className = "block-scroll";
    const img = doc.createElement("img");
    img.className = "block-img";
    img.alt = `${lang} diagram`;
    showPicture(img, picture);
    scroll.append(img);
    const toggle = doc.createElement("button");
    toggle.type = "button";
    toggle.className = "block-toggle";
    litRender(ICON, toggle);
    figure.append(scroll, toggle);
    return figure;
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
    holdingView(pre, () => {
      pre.before(figure);
      setSourceShown(figure, pre, false);
    }, () => figure.getBoundingClientRect().bottom);
  }

  // The <pre> stays as it is, under one muted line: never markup (the words are
  // a renderer's, driven by the model's input), and shown by CSS, so a bubble's
  // textContent, its dedupe and an annotation's text stay what they were (copy.js's
  // rule for its buttons).
  function fail(pre, lang, message) {
    if (!pre.isConnected) return;
    pre.dataset.blockFailed = "1";
    const note = doc.createElement("div");
    note.className = "block-note";
    const first = String(message ?? "").split("\n")[0].trim();
    const words = `Couldn't draw this ${lang} block${first ? `: ${first}` : ""}`;
    note.dataset.text = words;
    note.setAttribute("role", "note");
    note.setAttribute("aria-label", words);
    note.title = "Click to copy";
    pre.after(note);
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

  async function draw(pre, lang, source, renderer) {
    const now = theme(doc, win);
    const key = cacheKey(lang, now.name, source);
    const hit = cache.get(key);
    if (hit) { waiting.delete(pre); place(pre, hit, now.name, lang); return; }
    if (broken.has(lang)) { waiting.delete(pre); fail(pre, lang, broken.get(lang)); return; }
    let retry = false;
    try {
      place(pre, await pictureFor(key, lang, source, renderer, now), now.name, lang);
    } catch (e) {
      // A redraw that failed keeps the picture it has.
      if (!e?.dropped && !figureOf(pre)) fail(pre, lang, e?.message);
      retry = !!e?.dropped;
    } finally {
      waiting.delete(pre);
    }
    // Queued behind a frame that died (another block's timeout): a new frame's
    // turn. A session switch's frames go with their blocks, which aren't connected.
    // Each such death uses up one block, so this ends; the cap is for what would
    // otherwise spin the page if that ever stopped being true.
    if (!retry) return;
    const tries = (retries.get(pre) || 0) + 1;
    retries.set(pre, tries);
    if (tries <= MAX_RETRIES) consider(pre);
    else fail(pre, lang, "its renderer keeps stopping");
  }

  // A copy.js wrap took the <pre> away from a figure placed first: back with it.
  function rejoin(pre) {
    if (figureOf(pre) || !pre.hidden) return;
    const wrap = pre.parentElement;
    const stray = wrap?.classList.contains("code-wrap") && wrap.previousElementSibling;
    if (stray?.classList?.contains(DRAWN)) wrap.insertBefore(stray, pre);
  }

  function watchFor(entry) {
    const scroller = scrollerOf(entry.target, rootOf(entry.target), win);
    if (scroller === entry.scroller) return;
    entry.scroller = scroller;
    near(entry.target, scroller, entry.start);
  }

  function consider(pre) {
    if (!pre.isConnected || !pre.closest(TEXTS) || pre.dataset.blockFailed) return;
    const pending = waiting.get(pre);
    if (pending) {
      if (!pending.drawing) watchFor(pending);
      return;
    }
    rejoin(pre);
    const lang = pre.getAttribute("data-lang");
    const source = pre.textContent;
    if (!source.trim()) return; // an empty fence is left alone
    withRenderers((renderers) => {
      const renderer = renderers.get(lang);
      if (!renderer || !pre.isConnected || waiting.has(pre) || pre.dataset.blockFailed) return;
      const now = theme(doc, win);
      const figure = figureOf(pre);
      if (figure && figure.dataset.theme === now.name) return;
      const hit = cache.get(cacheKey(lang, now.name, source));
      if (hit) { place(pre, hit, now.name, lang); return; } // no flash: this frame
      if (!figure) {
        if (new TextEncoder().encode(source).length > MAX_SOURCE_BYTES) { fail(pre, lang, "it is over 64 KB"); return; }
        const mark = markKey(lang, source);
        if (storage.has(mark) && !inFlight.has(mark)) { fail(pre, lang, "it hung or took too long the last time"); return; }
      }
      // A drawn block's <pre> is hidden, which never intersects: its figure does.
      const entry = {
        target: figure || pre,
        scroller: null,
        drawing: false,
        start: () => { entry.drawing = true; draw(pre, lang, source, renderer); },
      };
      waiting.set(pre, entry);
      watchFor(entry);
    });
  }

  function scan(el) {
    if (el.matches?.(BLOCKS)) consider(el);
    for (const pre of el.querySelectorAll?.(BLOCKS) || []) consider(pre);
  }

  for (const root of roots) {
    new win.MutationObserver((records) => {
      noticeSession();
      for (const record of records) {
        for (const node of record.addedNodes) if (node.nodeType === 1) scan(node);
      }
    }).observe(root, { childList: true, subtree: true });
    scan(root);

    root.addEventListener("mousedown", (e) => {
      if (e.target.closest?.(".block-toggle")) e.preventDefault();
    });
    // Delegated, so a Revise clone's work too.
    root.addEventListener("click", (e) => {
      const toggle = e.target.closest?.(".block-toggle");
      if (toggle) {
        e.preventDefault();
        e.stopPropagation();
        const figure = toggle.parentElement;
        setSourceShown(figure, figure.nextElementSibling, !figure.classList.contains("source"));
        return;
      }
      const note = e.target.closest?.(".block-note");
      if (note) { copy(note.dataset.text); return; }
      if (e.target.closest?.(".block-img")) e.target.closest(`.${DRAWN}`).classList.toggle("natural");
    });
  }

  win.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
    for (const root of roots) scan(root);
  });

  return { scan, dropFrames };
}
