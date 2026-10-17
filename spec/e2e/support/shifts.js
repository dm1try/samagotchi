// Layout measurements for the e2e scenarios (stage.spec.js, web.spec.js):
// the layout-shift entries (CLS) with their sources, a 100 ms sampler of
// the stage's height, a per-frame watch of a waiting card, and the snap
// sampler (a tracked node moving more than 2 px between two frames when
// nothing animates it).

// Layout shifts (the CLS entries) on this page and after each reload:
// window.shifts, each {t, v, input (within 500 ms of a click or key), where
// (where its moved nodes are: "history", "stage", else "other"), sources
// ([{node, prev, cur}]: the moved node's path and its rects' [y, height])}.
// Self-contained: it runs as an init script too.
export function recordShifts() {
  window.shifts = [];
  const one = (e) => e.tagName.toLowerCase() + (e.id ? `#${e.id}` : "") + [...e.classList].slice(0, 3).map((c) => `.${c}`).join("");
  const path = (n) => {
    if (!n || !n.tagName) return String(n && n.nodeName);
    return [n.parentElement?.parentElement, n.parentElement, n].filter(Boolean).map(one).join(" > ");
  };
  const rect = (r) => [Math.round(r.y), Math.round(r.height)];
  new PerformanceObserver((list) => {
    const within = (sel, node) => !!document.querySelector(sel)?.contains(node);
    for (const e of list.getEntries()) {
      const places = e.sources.map((src) => (within("#history", src.node) ? "history" : within("#turnStage", src.node) ? "stage" : "other"));
      const sources = e.sources.map((src) => ({ node: path(src.node), prev: rect(src.previousRect), cur: rect(src.currentRect) }));
      window.shifts.push({ t: e.startTime, v: e.value, input: e.hadRecentInput, where: [...new Set(places)].join(" "), sources });
    }
  }).observe({ type: "layout-shift", buffered: true });
}

export async function watchShifts(page) {
  await page.addInitScript(recordShifts);
  await page.evaluate(recordShifts);
}

// The shifts' sum in [from, to) (page clock, ms), without the ones a click
// or key caused (with them: +withInput+); +where+ keeps only the shifts of
// that place.
export const shiftSum = (page, { from = 0, to = 1e12, where = null, withInput = false } = {}) => page.evaluate(([from, to, where, withInput]) =>
  window.shifts.filter((s) => (withInput || !s.input) && s.t >= from && s.t < to && (!where || s.where === where)).reduce((sum, s) => sum + s.v, 0),
[from, to, where, withInput]);

// The moved nodes' paths of the shifts in [from, to), input or not.
export const shiftSources = (page, { from = 0, to = 1e12 } = {}) => page.evaluate(([from, to]) =>
  [...new Set(window.shifts.filter((s) => s.t >= from && s.t < to).flatMap((s) => s.sources.filter((src) => src.prev.join() !== src.cur.join()).map((src) => src.node)))],
[from, to]);

export const pageNow = (page) => page.evaluate(() => performance.now());

// Samples the stage's height and the history's scrollTop every 100 ms until
// stopSampling(): window.samples.
export async function startSampling(page) {
  await page.evaluate(() => {
    window.samples = [];
    window.sampler = setInterval(() => {
      const s = document.querySelector("#turnStage");
      window.samples.push({
        h: s.offsetHeight, hidden: s.hidden, ended: s.classList.contains("ended") || s.classList.contains("leaving"),
        // The live slots (status, prompt, headline/tool/trail, the chip's
        // footer); the extras (a card: here check-in's, after 3 calls) may
        // add below them.
        slots: [".ts-status", ".ts-prompt", ".ts-live", ".ts-foot"].reduce((sum, sel) => sum + s.querySelector(sel).offsetHeight, 0),
        extras: s.querySelector(".ts-extras").offsetHeight,
        top: document.querySelector("#history").scrollTop,
        t: performance.now(),
      });
    }, 100);
  });
}
export const stopSampling = (page) => page.evaluate(() => { clearInterval(window.sampler); return window.samples; });

// Every frame: whether a question card waits in the stage and whether the
// asking text shows (window.frames2); frames() reads them.
export const watchFrames = (page) => page.evaluate(() => {
  window.frames2 = [];
  cancelAnimationFrame(window.framesRaf);
  const tick = () => {
    const s = document.querySelector("#turnStage");
    const waits = !!s.querySelector(".ts-extras .bubble.question:not(.answered):not(.cancelled)");
    window.frames2.push({ waits, asking: !s.querySelector(".ts-asking").hidden, phase: s.dataset.phase, t: performance.now() });
    window.framesRaf = requestAnimationFrame(tick);
  };
  tick();
});
export const frames = (page) => page.evaluate(() => window.frames2);

// The snap sampler: every frame, the top of each tracked node (the stage's
// status row and prompt line, a card in its extras, its chip, the composer
// card, the history's last child). A node that moves more than 2 px from
// one frame to the next is a snap, unless the stage itself animates (for
// its own nodes: stage.getAnimations(), not its subtree: the ticks blink
// forever), the
// node animates itself (a turn's arrival in the history) or an eased
// follow runs ([data-following] on the history or the stage's scroller).
// A replaced or removed node starts a new track (not a move). A gap between
// two frames longer than the stage's growth ease (a starved page under load)
// starts new tracks too: the ease may have run entirely inside it unseen.
export const startSnaps = (page) => page.evaluate(() => {
  cancelAnimationFrame(window.snapRaf);
  window.snapLog = [];
  const tracked = {
    status: () => document.querySelector("#turnStage .ts-status"),
    prompt: () => document.querySelector("#turnStage .ts-prompt"),
    card: () => document.querySelector("#turnStage .ts-extras > .bubble.question, #turnStage .ts-extras > .plugin-card"),
    chip: () => document.querySelector("#turnStage .ts-chip"),
    composer: () => document.querySelector(".dock-card"),
    last: () => document.querySelector("#history")?.lastElementChild,
  };
  let prev = {};
  let prevT = 0;
  const tick = () => {
    const stage = document.querySelector("#turnStage");
    const stageMoves = !!stage && stage.getAnimations().length > 0;
    const following = !!document.querySelector("#history[data-following], #turnStage [data-following]");
    const t = performance.now();
    const gap = prevT && t - prevT > 180;
    prevT = t;
    const next = {};
    for (const [key, find] of Object.entries(tracked)) {
      const el = find();
      if (!el || !el.isConnected || el.getClientRects().length === 0) continue;
      const top = el.getBoundingClientRect().top;
      const own = el.getAnimations().length > 0;
      next[key] = { el, top, exempt: following || own || (stageMoves && !!stage?.contains(el)) };
      const was = prev[key];
      if (was && !gap && was.el === el && Math.abs(top - was.top) > 2 && !next[key].exempt && !was.exempt) {
        window.snapLog.push({ t, key, from: Math.round(was.top), to: Math.round(top) });
      }
    }
    prev = next;
    window.snapRaf = requestAnimationFrame(tick);
  };
  tick();
});
// The snaps in [from, to) (page clock, ms), optionally of the given keys.
export const snaps = (page, { from = 0, to = 1e12, keys = null } = {}) => page.evaluate(([from, to, keys]) =>
  (window.snapLog || []).filter((s) => s.t >= from && s.t < to && (!keys || keys.includes(s.key))),
[from, to, keys]);

// Each time the stage's state changes (hidden, its classes, its phase, the
// extras' count), a mark {t, hidden, cls, phase, extras}: the moments'
// clock (window.stageMarks), taken in the change's own task (a mutation
// observer), so a shift it causes comes after its mark. stageMarks() reads
// them; momentAt() finds the first mark at or after +from+ that +test+
// accepts. No stage (the turn view): no marks.
export const watchStage = (page) => page.evaluate(() => {
  window.stageObserver?.disconnect();
  window.stageMarks = [];
  const s = document.querySelector("#turnStage");
  if (!s) return;
  let last = "";
  const markNow = () => {
    const mark = { hidden: s.hidden, cls: s.className, phase: s.dataset.phase || "", extras: s.querySelector(".ts-extras").children.length };
    const key = JSON.stringify(mark);
    if (key !== last) window.stageMarks.push({ t: performance.now(), ...mark });
    last = key;
  };
  window.stageObserver = new MutationObserver(markNow);
  window.stageObserver.observe(s, { attributes: true, attributeFilter: ["class", "hidden", "data-phase"] });
  window.stageObserver.observe(s.querySelector(".ts-extras"), { childList: true });
  markNow();
});
export const stageMarks = (page) => page.evaluate(() => window.stageMarks || []);
export const momentAt = (marks, test, from = 0) => marks.find((m) => m.t >= from && test(m))?.t;
