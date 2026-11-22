// A block the owner's page couldn't draw in the newest answer, asked for again
// once (docs/internals/block-renderers.md, A failed block is asked for again):
// POST /api/sessions/:id/blocks/fix, then the worker's :block_fix says how it
// went, and a fixed answer is read again and drawn as any answer.
//
// Only the owner's page asks (a viewer with the bundles' renderers), and only
// with <body data-block-fix="auto"> (web.block_fix; a page served by an older
// chi web has none: off). What a block gets, from the DOM alone:
//   - not marked fixable by its drawer (block_watch.js failBlock), or over
//     16 KB: today's line;
//   - data-block-fixed (it is a fix, failing again): "also after a fix" and Ask in chat;
//   - data-block-fix-failed (asked before, no help): "a fix didn't help" and Ask in chat;
//   - not in the newest answer, or past the answer's 2 blocks: today's line and Ask in chat;
//   - a live worker without the block_fix feature (worker_features.js
//     workerPredates): "restart this session to fix"; a worker not up, or not
//     reported yet, is asked (chi web answers 503 not_live: today's line);
//   - else "asking for a fix…" and the POST.
// A Revise clone has no data-answer-turn, so it never asks. Nothing is kept
// across a re-render: a block that fails again is posted again and the worker
// says it is running (or how it went). Only the redraw is counted: an answer
// is read again at most once per block for the page's life, so no answer of
// the worker's (a "fixed" for a copy still failing) can make a loop.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

import { api } from "./data.js";
import { codeText, copySource } from "./copy.js";
import { setAnswerRefs } from "./answer_refs.js";
import { askText, markFixed, noteOf, setFixNote } from "./block_fix_note.js";
import { stillOn } from "./latest.js";
import { TEXTS } from "./text_roots.js";
import { withDraft } from "./widget_picks.js";
import { OWNER_FINAL } from "./verify_target.js";
import { workerPredates } from "./worker_features.js";

export const FEATURE = "block_fix";
// BlockFix::MAX_SOURCE_BYTES and its per-answer count (BlockFix::PER_ANSWER).
export const MAX_SOURCE_BYTES = 16 * 1024;
export const PER_ANSWER = 2;
// No :block_fix this long after a 202 (the worker died, a reset lost it): give up.
export const GIVE_UP_MS = 60_000;

const FAILED = "pre[data-block-failed]";
const ANSWER = `${OWNER_FINAL.answers}[data-answer-turn]`;

// @param roots the turn roots (app.js turnRoots())
// @param sessionId () => the open session's id
// @param features () => the open session's worker features
// @param bridgeUp () => whether the open session's worker is up (store.current.bridgeUp)
// @param post (id, body) => a Promise of {status, body} (the route's answer)
// @param getSession data.js getSession (the answer's tail read)
// @param composerText () => the composer's text; fillComposer(text) sets it
// @param linkTextRefs () => the answers' refs again (markdown_place.js)
// @param timers {setTimeout, clearTimeout}: a seam for the specs
export function createBlockFix({ roots, sessionId, features, bridgeUp = () => true, post, getSession, composerText,
  fillComposer, linkTextRefs = () => {}, timers = globalThis, win = window }) {
  // Per answer bubble: the sources it asked for (at most PER_ANSWER).
  const asked = new WeakMap();
  // Give-up timers of the open session, by its id.
  let pending = new Map();
  // The open session's "turn\0source" whose answer was read again for it.
  let redrawn = new Set();
  let session = sessionId();

  function noticeSession() {
    const now = sessionId();
    if (now === session) return;
    session = now;
    for (const timer of pending.values()) timers.clearTimeout(timer);
    pending = new Map();
    redrawn = new Set();
  }

  // Whether the answer may be read again for +source+ (once), noting it.
  function redrawOnce(turnId, source) {
    const key = `${turnId}\0${source}`;
    if (redrawn.has(key)) return false;
    redrawn.add(key);
    return true;
  }

  function newestAnswer() {
    let newest = null;
    for (const root of roots) {
      const all = root.querySelectorAll(OWNER_FINAL.answers);
      if (all.length) newest = all[all.length - 1];
    }
    return newest;
  }

  const tooLarge = (source) => new TextEncoder().encode(source).length > MAX_SOURCE_BYTES;

  function decide(pre) {
    if (!pre.isConnected || !pre.closest(TEXTS) || pre.dataset.blockFixSeen === "1") return;
    pre.dataset.blockFixSeen = "1";
    noticeSession();
    const source = codeText(pre);
    if (pre.dataset.blockFixable !== "1" || tooLarge(source)) return;
    if (pre.hasAttribute("data-block-fixed")) { setFixNote(pre, "again"); return; }
    if (pre.hasAttribute("data-block-fix-failed")) { setFixNote(pre, "nohelp"); return; }
    const bubble = pre.closest(ANSWER);
    const sources = bubble && (asked.get(bubble) || new Set());
    if (!bubble || bubble !== newestAnswer() || (sources.size >= PER_ANSWER && !sources.has(source))) {
      setFixNote(pre, "older");
      return;
    }
    if (workerPredates(features(), bridgeUp(), FEATURE)) { setFixNote(pre, "restart"); return; }
    sources.add(source);
    asked.set(bubble, sources);
    setFixNote(pre, "asking");
    ask(pre, bubble.getAttribute("data-answer-turn"), source);
  }

  async function ask(pre, turnId, source) {
    const id = sessionId();
    const still = stillOn(sessionId, id);
    const lang = pre.getAttribute("data-lang");
    // Marked before the POST: the worker's word can come before its 202 (a
    // quick side answer), and the event settles the blocks marked so.
    pre.dataset.blockFixAsked = "1";
    let answer;
    try {
      answer = await post(id, { turn_id: turnId, lang, source, reason: pre.dataset.blockReason || "" });
    } catch (_) {
      answer = { status: 0, body: {} };
    }
    if (!still() || !pre.isConnected) return;
    const { status, body = {} } = answer;
    if (status !== 202) delete pre.dataset.blockFixAsked;
    if (status === 200 && body.state === "fixed") {
      // Drawn again and failed again after a redraw: no second one.
      if (redrawOnce(turnId, source)) refresh(id, turnId);
      else setFixNote(pre, "nohelp");
      return;
    }
    if (status === 200) { setFixNote(pre, "nohelp"); return; }
    if (status === 202) {
      if (typeof body.key === "string" && body.key) pre.dataset.blockFixKey = body.key;
      // Running, unless the worker's word already came.
      if (asking(pre)) giveUpLater(turnId);
      return;
    }
    setFixNote(pre, status === 501 ? "restart" : "older");
  }

  function giveUpLater(turnId) {
    if (pending.has(turnId)) timers.clearTimeout(pending.get(turnId));
    pending.set(turnId, timers.setTimeout(() => {
      pending.delete(turnId);
      for (const pre of askedIn(turnId)) if (asking(pre)) setFixNote(pre, "older");
    }, GIVE_UP_MS));
  }

  const asking = (pre) => noteOf(pre)?.dataset.fix === "asking";

  function bubbleOf(turnId) {
    for (const root of roots) {
      for (const found of root.querySelectorAll(ANSWER)) if (found.getAttribute("data-answer-turn") === turnId) return found;
    }
    return null;
  }

  function askedIn(turnId) {
    const bubble = bubbleOf(turnId);
    return bubble ? [...bubble.querySelectorAll(`${FAILED}[data-block-fix-asked]`)] : [];
  }

  // The fixed answer, read again and written as applyFinalAnswer writes it
  // (answer_refs.js), which can't find the bubble by its old text.
  async function refresh(id, turnId) {
    const still = stillOn(sessionId, id);
    let data;
    try {
      data = await getSession(id, { tail: true, turnId });
    } catch (_) {
      return;
    }
    if (!still()) return;
    const message = [...(data?.messages || [])].reverse().find((m) => m?.role === "assistant" && typeof m.html === "string");
    const bubble = bubbleOf(turnId);
    if (!message || !bubble) return;
    // A turn no prompt names (a reminder's) is read as the newest answer: only
    // that bubble may take it; another waits for the next full read.
    if (bubble !== newestAnswer() && bubble.getAttribute("data-copy-source") !== message.content) return;
    bubble.classList.add("markdown");
    bubble.setAttribute("data-copy-source", copySource(message));
    bubble.toggleAttribute("data-answer-display", typeof message.display === "string");
    bubble.innerHTML = message.html;
    setAnswerRefs(bubble, message.display_refs);
    linkTextRefs();
  }

  // The worker's word on a fix it was asked for (stream_handlers.js).
  function onEvent(data) {
    noticeSession();
    const turnId = data?.turn_id;
    if (!turnId) return;
    const asked = askedIn(turnId);
    const relevant = data.key ? asked.filter((pre) => !pre.dataset.blockFixKey || pre.dataset.blockFixKey === data.key) : asked;
    if (!relevant.length) return;
    for (const pre of relevant) delete pre.dataset.blockFixAsked;
    if (pending.has(turnId) && !askedIn(turnId).some(asking)) {
      timers.clearTimeout(pending.get(turnId));
      pending.delete(turnId);
    }
    if (data.state === "fixed") {
      for (const pre of relevant) redrawOnce(turnId, codeText(pre));
      refresh(sessionId(), turnId);
      return;
    }
    for (const pre of relevant) setFixNote(pre, "nohelp");
  }

  function scan(el) {
    if (el.matches?.(FAILED)) decide(el);
    for (const pre of el.querySelectorAll?.(FAILED) || []) decide(pre);
    if (el.matches?.("pre[data-block-fixed]")) markFixed(el);
    for (const pre of el.querySelectorAll?.("pre[data-block-fixed]") || []) markFixed(pre);
  }

  for (const root of roots) {
    root.addEventListener("block-failed", (e) => {
      const pre = e.target;
      if (pre?.matches?.("pre[data-block-fixed]")) markFixed(pre);
      decide(pre);
    });
    // A Revise clone arrives failed; a figure placed is a drawn block (its
    // "Drawn after a fix" line).
    new win.MutationObserver((records) => {
      for (const record of records) {
        for (const node of record.addedNodes) {
          if (node.nodeType !== 1) continue;
          if (node.classList?.contains("block-drawn") && node.nextElementSibling?.matches?.("pre[data-block-fixed]")) {
            markFixed(node.nextElementSibling);
          } else scan(node);
        }
      }
    }).observe(root, { childList: true, subtree: true });
    // One delegated listener per root: a clone loses element listeners.
    root.addEventListener("click", (e) => {
      const button = e.target.closest?.(".block-note > .block-fix-ask");
      if (!button) return;
      e.preventDefault();
      e.stopPropagation();
      const pre = button.parentElement.previousElementSibling;
      if (!pre?.matches?.("pre")) return;
      fillComposer(withDraft(composerText(), askText(pre.getAttribute("data-lang"), pre.dataset.blockReason)));
    });
    scan(root);
  }

  return { onEvent, scan };
}

// The route's POST as {status, body}: 202 is the one answer that says
// "running"; a refusal's status is data.js api's error.status (0: no answer).
export async function postFix(id, body, { fetchImpl } = {}) {
  try {
    const answer = await api(`/api/sessions/${encodeURIComponent(id)}/blocks/fix`, {
      method: "POST", body: JSON.stringify(body), ...(fetchImpl ? { fetchImpl } : {}),
    });
    return { status: answer?.state === "running" ? 202 : 200, body: answer || {} };
  } catch (e) {
    return { status: e?.status || 0, body: {} };
  }
}

// app.js's wiring: the owner's page with web.block_fix auto, else null (the
// stream handler's dep stays null too).
export function wireBlockFix({ viewer, roots, store, getSession, composerText, fillComposer, linkTextRefs, doc = document }) {
  if (!viewer.can("block_renderers") || doc.body?.dataset?.blockFix !== "auto") return null;
  return createBlockFix({
    roots, sessionId: () => store.selected, features: () => store.current.workerFeatures,
    bridgeUp: () => store.current.bridgeUp, post: (id, body) => postFix(id, body),
    getSession, composerText, fillComposer, linkTextRefs,
  });
}
