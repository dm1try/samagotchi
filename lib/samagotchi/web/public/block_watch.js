// Finds and watches the fenced blocks a drawer may draw (docs/internals/block-renderers.md).
// One observer per turn root, filtered to TEXTS, as copy.js and answer_fold.js:
// every path that fills a root (a reload, a session switch, a turn's end, an
// answer_display, Revise's clones, a step's swap) arrives the same way, and
// cards, the asking slot and question replies are never touched. A block is
// drawn when it comes near its scroller's view (a closed <details> opening is
// such a coming near), and one that moves to another scroller while it waits
// (the stage's hand-off to #history) is watched there.
//
// What draws is a drawer's: block_host.js's frames for a bundle's renderers,
// after any core drawers. The DOM is the state, as block_source.js says: a
// figure right before the <pre> says it is drawn, data-block-failed on the
// <pre> says it isn't to be tried again.
//
// The drawer contract:
// - claims(lang): true when it draws this language. A Promise of that when it
//   can't say yet (the bundle drawer's list): the next drawer is asked only
//   after it says no. The first that claims draws; a language no drawer claims
//   is left alone.
// - needsDraw(pre, figure): whether the block is to be watched and drawn.
//   +figure+ is its drawn figure or null: a drawn block comes here too (the
//   frame drawer redraws one in another theme). It may settle the block on the
//   spot (a cache hit placed, a refusal's line) and say false.
// - draw(pre, { reconsider }): draws it now; a Promise while it runs, during
//   which the block isn't watched again. reconsider(pre) has the watcher look
//   at the block afresh (a draw that has to try again).
// - sessionChanged() (optional): the open session changed.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

import { DRAWN, figureOf, setSourceShown } from "./block_source.js";
import { copyText } from "./copy.js";
import { keepFollowing, shouldFollowScroll } from "./scroll.js";
import { TEXTS } from "./text_roots.js";

const BLOCKS = "pre[data-lang]";
const IO_MARGIN = "600px 0px";

// The nearest scroller holding +el+, +root+ at the latest. IntersectionObserver
// needs it named: with root:null a rootMargin doesn't pass an overflow:auto
// between, so a block just under #history's fold wouldn't count.
export function scrollerOf(el, root, win = window) {
  for (let at = el.parentElement; at && at !== root; at = at.parentElement) {
    const { overflowY } = win.getComputedStyle(at);
    if (overflowY === "auto" || overflowY === "scroll") return at;
  }
  return root;
}

const rootOf = (roots, el) => roots.find((root) => root.contains(el)) || roots[0];

// +mutate+ with the view held: a viewer at the bottom stays there, and a
// block above a reader's view keeps what they read where it is. Browsers that
// anchor scrolling have done it by the second read, and there is nothing left.
// @param bottomOf () => the inserted thing's bottom, after +mutate+
export function holdingView(pre, roots, mutate, bottomOf, win = window) {
  const scroller = scrollerOf(pre, rootOf(roots, pre), win);
  if (shouldFollowScroll(scroller)) return keepFollowing(scroller, mutate);
  const before = pre.getBoundingClientRect().bottom;
  if (before > scroller.getBoundingClientRect().top) return mutate();
  const result = mutate();
  const after = bottomOf();
  if (after !== before) scroller.scrollTop += after - before;
  return result;
}

// The <pre> stays as it is, under one muted line: never markup (the words are
// a drawer's, driven by the model's input), and shown by CSS, so a bubble's
// textContent, its dedupe and an annotation's text stay what they were (copy.js's
// rule for its buttons). A click on the line copies it (the watcher's listener).
export function failBlock(pre, lang, message) {
  if (!pre.isConnected) return;
  pre.dataset.blockFailed = "1";
  const note = pre.ownerDocument.createElement("div");
  note.className = "block-note";
  const first = String(message ?? "").split("\n")[0].trim();
  const words = `Couldn't draw this ${lang} block${first ? `: ${first}` : ""}`;
  note.dataset.text = words;
  note.setAttribute("role", "note");
  note.setAttribute("aria-label", words);
  note.title = "Click to copy";
  pre.after(note);
}

// A copy.js wrap took the <pre> away from a figure placed first: back with it.
export function rejoin(pre) {
  if (figureOf(pre) || !pre.hidden) return;
  const wrap = pre.parentElement;
  const stray = wrap?.classList.contains("code-wrap") && wrap.previousElementSibling;
  if (stray?.classList?.contains(DRAWN)) wrap.insertBefore(stray, pre);
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

// @param roots the turn roots (app.js turnRoots())
// @param sessionId () => the open session's id: a change tells the drawers
// @param drawers in order: the first that claims a block's language draws it
// @param watch (el, scroller, onNear) => calls onNear once el comes near; a seam
//   for the specs
export function createBlockWatch({ roots, sessionId, drawers, watch = null, copy = copyText, win = window }) {
  const near = watch || ioWatcher(win);
  // Blocks with a draw on its way (not a drawn state: that is the figure): pre =>
  // {target, scroller, start, drawing}. Until it starts, a block whose scroller
  // changed (the stage's hand-off to the history) gets watched there.
  const waiting = new WeakMap();
  let session = sessionId();

  function noticeSession() {
    const now = sessionId();
    if (now === session) return;
    session = now;
    for (const drawer of drawers) drawer.sessionChanged?.();
  }

  // The drawer claiming +lang+, to +fn+: at once when each one asked can say.
  function pick(lang, fn, from = 0) {
    for (let i = from; i < drawers.length; i++) {
      const drawer = drawers[i];
      const claimed = drawer.claims(lang);
      if (claimed?.then) {
        claimed.then((yes) => (yes ? fn(drawer) : pick(lang, fn, i + 1)), () => pick(lang, fn, i + 1));
        return;
      }
      if (claimed) { fn(drawer); return; }
    }
  }

  function watchFor(entry) {
    const scroller = scrollerOf(entry.target, rootOf(roots, entry.target), win);
    if (scroller === entry.scroller) return;
    entry.scroller = scroller;
    near(entry.target, scroller, entry.start);
  }

  function reconsider(pre) {
    if (waiting.get(pre)?.drawing) waiting.delete(pre);
    consider(pre);
  }

  function start(entry, pre, drawer) {
    entry.drawing = true;
    const over = () => { if (waiting.get(pre) === entry) waiting.delete(pre); };
    let drawing;
    try {
      drawing = drawer.draw(pre, { reconsider });
    } catch (e) {
      over();
      throw e;
    }
    Promise.resolve(drawing).then(over, over);
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
    if (!pre.textContent.trim()) return; // an empty fence is left alone
    pick(lang, (drawer) => {
      if (!pre.isConnected || waiting.has(pre) || pre.dataset.blockFailed) return;
      const figure = figureOf(pre);
      if (!drawer.needsDraw(pre, figure)) return;
      // A drawn block's <pre> is hidden, which never intersects: its figure does.
      const entry = { target: figure || pre, scroller: null, drawing: false, start: () => start(entry, pre, drawer) };
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
      if (note) copy(note.dataset.text);
    });
  }

  return { scan, reconsider };
}
