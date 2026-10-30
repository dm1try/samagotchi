// Revise stacks (web): a Revise turn rewrites an earlier turn's answer, and
// the server stamps its prompt with `revises: {turn_id}` once it completed
// with an answer (Engine#stamp_opening; never derived here). The page draws
// each stack v1 ← v2 ← … ← top in place:
//
// - every superseded turn (its opening, its work, its answer: turn_range.js's
//   rule) is hidden by a class and replaced, where it is, by one stub row,
//   "v1 · ‹first line› · 84 lines — superseded by v3"; a click unfolds the
//   turn in place (per viewer: answer_fold.js's store, the key "stub:<id>").
//   Not hidden: the cards a turn's end keeps out of its block (warn cards),
//   verdict cards, the recap. A time-gap divider between two folded stubs
//   folds into the later stub (it shows the divider's words);
// - the top answer gets a version chip, "v3 · 2 earlier ▾", listing the
//   versions by their prompts; picking one reveals its stub; and a ‹ 3/3 ›
//   switcher before it shows an earlier version's answer in the top
//   answer's place (revise_switch.js; view only, not stored);
// - the final answer of an ended turn (verify_target.js's rule, a delegate
//   report's reply excluded), unstacked or a stack's top, and not a Verify
//   turn's, gets a Revise button: it arms the composer (app.js).
//
// The stamps live on the history's prompt bubbles (data-revises: a reload's
// render, a live turn_completed's revises), so the stacks are read from the
// DOM again on every change (stacks(), pure). One observer on #history, as
// answer_fold.js has; history_reveal.js unfolds a stub a jump lands in.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { html, nothing, render } from "./vendor/lit-html.js";
import { bubbleCopyText } from "./copy.js";
import { foldLabel, keepRowInView, lineCount, readFolded, writeFold } from "./answer_fold.js";
import { clip } from "./format.js";
import { NOTE_BOUNDARY } from "./turn_range.js";
import { SWAPPED_CLASS, VIEW_CLASS, stepVersion, switcherTemplate, viewOf } from "./revise_switch.js";

// The classes and attributes this module puts on the history.
export const HIDDEN_CLASS = "stack-hidden";
export const STUB_CLASS = "stack-stub";
export const ROW_CLASS = "revise-row";
const GAP_HIDDEN_CLASS = "stack-gap";
// What a superseded turn keeps on view (card.js leavesBlock's cards, a
// verdict, the recap).
export const KEPT = ".plugin-card.warn, .verify-verdict, .bubble.recap";
// A turn's final answer (verify_target.js OWNER_FINAL), and not done yet.
const ANSWERS = ".bubble.output:not(.report-reply)";
const UNFINISHED = ".streaming";
const OPENING = "[data-turn-id]";
// A fold row (answer_fold.js) just before an opening: a delegate report's
// that opens its turn, the opening's header (in its range, the stub above it).
const FOLD_ROW = "answer-fold";
const headOf = (opening) => (opening.previousElementSibling?.classList.contains(FOLD_ROW) ? opening.previousElementSibling : null);
const STOPPED = ".bubble.cancel";
const LABEL_CHARS = 120;
// The stored key of a stub unfolded by hand (answer_fold.js's list).
export const stubKey = (turnId) => `stub:${turnId}`;

// The chains of revisions among +messages+ (the history's openings, in
// order: {turn_id, revises?: {turn_id}}), each [v1, v2, …, top] by turn id;
// only chains of two or more. A revises whose target isn't an earlier
// opening is ignored (a stale page, a rolled-back turn); one whose target
// was revised already goes on that stack's top (as the server re-targets).
export function stacks(messages) {
  const order = new Map();
  const revisesOf = new Map();
  for (const m of Array.isArray(messages) ? messages : []) {
    const id = m?.turn_id;
    if (typeof id !== "string" || !id || order.has(id) || m.merged) continue;
    order.set(id, order.size);
    const target = m.revises?.turn_id;
    if (typeof target === "string" && target) revisesOf.set(id, target);
  }
  const next = new Map();
  const prev = new Map();
  for (const [id, at] of order) {
    let target = revisesOf.get(id);
    if (!target || !order.has(target) || order.get(target) >= at) continue;
    while (next.has(target)) target = next.get(target);
    next.set(target, id);
    prev.set(id, target);
  }
  const chains = [];
  for (const id of order.keys()) {
    if (prev.has(id) || !next.has(id)) continue;
    const chain = [id];
    while (next.has(chain.at(-1))) chain.push(next.get(chain.at(-1)));
    chains.push(chain);
  }
  return chains;
}

// A stub's words: "v1 · "‹label›" · 84 lines — superseded by v3".
export function stubText({ version, label = "", lines = 0, top }) {
  const said = label ? ` · “${label}”` : "";
  const size = lines ? ` · ${lines} line${lines === 1 ? "" : "s"}` : "";
  return `v${version}${said}${size} — superseded by v${top}`;
}

// The version chip's words: "v3 · 2 earlier".
export function versionChipText(count) {
  return `v${count} · ${count - 1} earlier`;
}

// The composer's chip: "Revising: ‹label›", or the refusal (+unavailable+:
// the worker predates Revise turns).
export const REVISE_UNAVAILABLE = "restart this session to use Revise";

// The feature gate (app.js featureGates): a live worker without the
// "revise" feature predates Revise turns (chi web would answer 409
// revise_unavailable). A worker that isn't up isn't asked: the send wakes a
// new one, which has it (as Verify's gate, verify_preset.js).
export function reviseWorkerUnavailable(workerFeatures, bridgeUp) {
  return bridgeUp === true && Array.isArray(workerFeatures) && !workerFeatures.includes("revise");
}
export function reviseChipText(label, { unavailable = false } = {}) {
  if (unavailable) return `Revise: ${REVISE_UNAVAILABLE}`;
  return label ? `Revising: ${label}` : "Revising the answer";
}

// The composer's chip (app.js renders it into its own element): the armed
// Revise's words and ✕ (+onClear+), or nothing when +anchor+ is null.
export function reviseChipTemplate(anchor, { unavailable = false, onClear } = {}) {
  if (!anchor) return nothing;
  return html`<span class=${unavailable ? "revise-chip refused" : "revise-chip"} title=${unavailable ? REVISE_UNAVAILABLE : `This message rewrites that answer: ${anchor.label || ""}`}><span class="revise-chip-text">${reviseChipText(anchor.label, { unavailable })}</span><button type="button" class="revise-chip-clear" aria-label="Don't revise" title="Don't revise (send as a plain message)" @click=${onClear}>✕</button></span>`;
}

// An answer's label (the stub's, the chip's): its first line.
export function answerLabel(bubble) {
  if (!bubble) return "";
  return foldLabel(bubbleCopyText(bubble), { display: bubble.hasAttribute?.("data-answer-display") });
}

// A prompt bubble's first text line (a version's label in the chip's list).
function promptLabel(opening) {
  if (!opening) return "";
  const text = opening.matches?.(".bubble.user") ? bubbleCopyText(opening) : opening.querySelector?.(".note-text")?.textContent || "";
  const line = String(text).split("\n").map((l) => l.trim()).find(Boolean) || "";
  return clip(line, LABEL_CHARS);
}

// The history's turns, in order (one pass over #history's children):
// {id, opening, els (after the opening, up to the next opening or note, a
// trailing gap divider left to the next), answer (its final answer), wake
// (a note opened it), stopped (it was canceled or failed)}. Our own rows
// aren't part of any.
export function historyTurns(historyEl) {
  const turns = [];
  let turn = null;
  const close = () => {
    if (!turn) return;
    while (turn.els.at(-1)?.classList.contains("time-gap")) turn.els.pop();
  };
  for (const el of historyEl.children) {
    if (el.classList.contains(STUB_CLASS) || el.classList.contains(ROW_CLASS) || el.classList.contains(VIEW_CLASS)) continue;
    if (el.classList.contains(FOLD_ROW) && el.nextElementSibling?.matches(OPENING)) continue;
    const opening = el.matches(OPENING) ? el : el.querySelector(OPENING);
    if (opening || el.matches(NOTE_BOUNDARY)) {
      close();
      turn = { id: opening?.dataset.turnId || null, opening: el, head: headOf(el), prompt: opening || null, els: [], answer: null, wake: !opening };
      turns.push(turn);
      continue;
    }
    if (!turn) continue;
    turn.els.push(el);
    if (el.matches(ANSWERS)) turn.answer = el;
    // A canceled or failed turn's end line (timing.js STOPPED_LINE_CLASS,
    // a live end's too): its partial answer isn't a completed one.
    if (el.matches(STOPPED)) turn.stopped = true;
  }
  close();
  // A wake turn's id is its answer's (timing.js turnGroups keys it).
  for (const t of turns) if (t.wake && t.answer) t.id = t.answer.getAttribute("data-answer-turn") || null;
  return turns;
}

// @param historyEl #history (also its scroller)
// @param sessionId () => the open session's id
// @param projectRoot () => its project root (the fold store's sweep), or null
// @param running () => null when no turn runs, else {turnId} (null id: the
//   newest turn counts as the running one)
// @param verifyTurn (turnId) => whether that turn was a Verify turn (beyond
//   its prompt's data-verify: a verdict's check_turn_id)
// @param unavailable () => the worker predates Revise (the feature gate)
// @param armed () => the turn id the composer's Revise is armed with, or null
// @param onRevise ({turn_id, label}) the Revise button
// @return {decorate()} (the observer runs it; app.js after a change it reads)
export function installReviseStacks({
  historyEl, sessionId, projectRoot = () => null, running = () => null, verifyTurn = () => false,
  unavailable = () => false, armed = () => null, onRevise = () => {},
}) {
  const stubs = new Map();
  const rows = new Map();
  // Each row's answer bubble (its label at a click).
  const rowAnswer = new WeakMap();
  // The switcher: each stack's version on view (0-based, by its top's id;
  // none: the latest), and the copy shown for it ({el, source, hidden}).
  const shown = new Map();
  const views = new Map();
  let observer = null;

  function stubFor(id, opening, stored) {
    let stub = stubs.get(id);
    if (!stub) {
      stub = historyEl.ownerDocument.createElement("button");
      stub.type = "button";
      stub.className = STUB_CLASS;
      stub.dataset.stackStub = id;
      // The stored choice, once: after that the stub's class is the state
      // (a jump's reveal isn't saved).
      if (stored().includes(stubKey(id))) stub.classList.add("open");
      stubs.set(id, stub);
    }
    const top = headOf(opening) || opening;
    if (stub.parentElement !== historyEl || stub.nextElementSibling !== top) historyEl.insertBefore(stub, top);
    return stub;
  }

  function drawStub(stub, { version, top, answer, opening, gap }) {
    const open = stub.classList.contains("open");
    stub.setAttribute("aria-expanded", open ? "true" : "false");
    stub.title = `${open ? "Fold" : "Show"} this earlier version${opening.title ? ` (${opening.title})` : ""}`;
    const text = stubText({ version, label: answerLabel(answer), lines: answer ? lineCount(bubbleCopyText(answer)) : 0, top });
    render(html`<span class="stack-stub-text">${text}</span>${gap ? html`<span class="stack-stub-gap">${gap}</span>` : nothing}`, stub);
  }

  function rowFor(id, answer) {
    let row = rows.get(id);
    if (!row) {
      row = historyEl.ownerDocument.createElement("div");
      row.className = ROW_CLASS;
      row.dataset.reviseFor = id;
      rows.set(id, row);
    }
    if (answer.nextElementSibling !== row) answer.after(row);
    return row;
  }

  function drawRow(row, { id, answer, chain, openings }) {
    const off = unavailable();
    const isArmed = armed() === id;
    const versions = chain
      ? html`<details class="stack-versions"><summary>${versionChipText(chain.length)}</summary><div class="stack-versions-list" role="list">${chain.map((vid, k) => html`<button type="button" role="listitem" class=${vid === id ? "stack-version current" : "stack-version"} data-stack-pick=${vid} ?disabled=${vid === id}><span class="stack-version-n">v${k + 1}</span> ${promptLabel(openings.get(vid))}</button>`)}</div></details>`
      : nothing;
    const button = html`<button type="button" class=${isArmed ? "revise-btn armed" : "revise-btn"} data-revise=${id} ?disabled=${off} title=${off ? REVISE_UNAVAILABLE : "Rewrite this answer: your next message revises it, and the earlier version folds away"}>${isArmed ? "Revising…" : "Revise"}</button>`;
    row.classList.toggle("stacked", !!chain);
    const at = chain ? (shown.get(id) ?? chain.length - 1) : 0;
    render(html`${chain ? switcherTemplate(id, at, chain.length) : nothing}${versions}${button}`, row);
    rowAnswer.set(row, answer);
  }

  function decorate() {
    let folds = null;
    const stored = () => (folds ??= readFolded(sessionId()));
    const turns = historyTurns(historyEl);
    const openings = new Map(turns.filter((t) => t.id).map((t) => [t.id, t.prompt || t.opening]));
    const entries = turns.filter((t) => t.id).map((t) => {
      const revises = t.prompt?.getAttribute("data-revises");
      return revises ? { turn_id: t.id, revises: { turn_id: revises } } : { turn_id: t.id };
    });
    const superseded = new Map();
    const tops = new Map();
    for (const chain of stacks(entries)) {
      chain.slice(0, -1).forEach((id, k) => superseded.set(id, { version: k + 1, top: chain.length }));
      tops.set(chain.at(-1), chain);
    }
    const run = running();
    const lastOpening = turns.filter((t) => !t.wake).at(-1);
    const keepStubs = new Set();
    const keepRows = new Set();
    for (const turn of turns) {
      const range = [turn.head, turn.opening, ...turn.els].filter(Boolean);
      const place = turn.id && superseded.get(turn.id);
      if (place) {
        const stub = stubFor(turn.id, turn.opening, stored);
        keepStubs.add(turn.id);
        const open = stub.classList.contains("open");
        for (const el of range) {
          const hide = !open && !el.matches(KEPT);
          el.classList.toggle(HIDDEN_CLASS, hide);
          if (el.dataset.stackOf !== turn.id) el.dataset.stackOf = turn.id;
        }
        turn.stub = stub;
        turn.place = place;
        continue;
      }
      for (const el of range) {
        if (el.classList.contains(HIDDEN_CLASS)) el.classList.remove(HIDDEN_CLASS);
        if (el.dataset.stackOf) delete el.dataset.stackOf;
      }
      // The Revise row: an ended turn's final answer, not a Verify turn's,
      // not the running turn's.
      const answer = turn.answer;
      if (!turn.id || turn.wake || !answer || answer.matches(UNFINISHED) || turn.stopped) continue;
      if (turn.prompt?.hasAttribute("data-verify") || verifyTurn(turn.id)) continue;
      if (run && (turn === lastOpening || (run.turnId && run.turnId === turn.id))) continue;
      const row = rowFor(turn.id, answer);
      keepRows.add(turn.id);
      drawRow(row, { id: turn.id, answer, chain: tops.get(turn.id) || null, openings });
    }
    syncViews(tops, keepRows, new Map(turns.filter((t) => t.id).map((t) => [t.id, t.answer])));
    // A divider between two folded stubs folds into the later one.
    for (const turn of turns) {
      if (!turn.stub) continue;
      const gap = turn.stub.previousElementSibling;
      let gapText = "";
      if (gap?.classList.contains("time-gap")) {
        let before = gap.previousElementSibling;
        while (before?.classList.contains(HIDDEN_CLASS)) before = before.previousElementSibling;
        const fold = !turn.stub.classList.contains("open") && !!before?.matches(`.${STUB_CLASS}:not(.open)`);
        gap.classList.toggle(GAP_HIDDEN_CLASS, fold);
        if (fold) gapText = gap.textContent.replace(/[─\s]+$/u, "").replace(/^[─\s]+/u, "");
      }
      drawStub(turn.stub, { ...turn.place, answer: turn.answer, opening: turn.prompt || turn.opening, gap: gapText });
    }
    for (const gap of historyEl.querySelectorAll(`:scope > .${GAP_HIDDEN_CLASS}`)) {
      if (!gap.nextElementSibling?.matches(`.${STUB_CLASS}:not(.open)`)) gap.classList.remove(GAP_HIDDEN_CLASS);
    }
    for (const [id, stub] of stubs) if (!keepStubs.has(id) || stub.parentElement !== historyEl) { stub.remove(); stubs.delete(id); }
    for (const [id, row] of rows) if (!keepRows.has(id) || row.parentElement !== historyEl) { row.remove(); rows.delete(id); }
    // A stale row left by a re-render (its map entry gone with the nodes).
    const viewEls = new Set([...views.values()].map((v) => v.el));
    for (const el of historyEl.querySelectorAll(`:scope > .${STUB_CLASS}, :scope > .${ROW_CLASS}, :scope > .${VIEW_CLASS}`)) {
      if (stubs.get(el.dataset.stackStub) !== el && rows.get(el.dataset.reviseFor) !== el && !viewEls.has(el)) el.remove();
    }
    // What we changed isn't news.
    observer?.takeRecords();
  }

  // The switcher's copies: a stack on an earlier version (its top's row
  // drawn, that version's answer there) shows a copy of that answer just
  // before the top answer and its fold row, which hide; any other stack's
  // copy goes and its top shows again.
  function syncViews(tops, keepRows, answers) {
    const wanted = (id) => {
      const chain = tops.get(id);
      const k = shown.get(id);
      if (!chain || k === undefined || k >= chain.length - 1 || !keepRows.has(id)) return null;
      const source = answers.get(chain[k]);
      const top = answers.get(id);
      return source && top ? { source, top, version: k + 1 } : null;
    };
    for (const [id, view] of views) {
      const want = wanted(id);
      if (want && view.source === want.source && view.top === want.top && view.el.isConnected) continue;
      view.el.remove();
      for (const el of view.hidden) el.classList.remove(SWAPPED_CLASS);
      views.delete(id);
    }
    for (const id of [...shown.keys()]) {
      const want = wanted(id);
      if (!want) {
        shown.delete(id);
        continue;
      }
      let view = views.get(id);
      if (!view) {
        view = { el: viewOf(want.source, want.version), source: want.source, top: want.top, hidden: [] };
        views.set(id, view);
      }
      const head = want.top.previousElementSibling?.classList.contains(FOLD_ROW) ? want.top.previousElementSibling : null;
      for (const el of view.hidden) if (el !== want.top && el !== head) el.classList.remove(SWAPPED_CLASS);
      view.hidden = head ? [want.top, head] : [want.top];
      for (const el of view.hidden) el.classList.add(SWAPPED_CLASS);
      const before = head || want.top;
      if (before.previousElementSibling !== view.el) historyEl.insertBefore(view.el, before);
    }
  }

  // The switcher's ‹ or › on its row's stack.
  function step(row, delta) {
    const id = row.dataset.reviseFor;
    const count = row.querySelectorAll("[data-stack-pick]").length;
    if (!id || count < 2) return;
    const was = shown.get(id) ?? count - 1;
    const k = stepVersion(was, count, delta);
    if (k === was) return;
    if (k === count - 1) shown.delete(id);
    else shown.set(id, k);
    keepRowInView(historyEl, row, decorate);
  }

  function setOpen(stub, open, { save }) {
    keepRowInView(historyEl, stub, () => {
      stub.classList.toggle("open", open);
      decorate();
    });
    if (save) writeFold(sessionId(), stubKey(stub.dataset.stackStub), open, { root: projectRoot() });
  }

  // Changes from elsewhere: a direct child added or removed, a stamp, an
  // answer's key or its end (its class).
  observer = new MutationObserver((records) => {
    const news = records.some((r) => (r.type === "childList" ? r.target === historyEl
      && [...r.addedNodes, ...r.removedNodes].some((n) => n.nodeType === 1 && ![STUB_CLASS, ROW_CLASS, VIEW_CLASS].some((c) => n.classList.contains(c)))
      : r.attributeName !== "class" || r.target.matches?.(`.bubble.output, .${STUB_CLASS}`)));
    if (news) decorate();
  });
  observer.observe(historyEl, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "data-revises", "data-answer-turn", "data-verify"] });
  decorate();

  historyEl.addEventListener("click", (e) => {
    const stub = e.target.closest?.(`.${STUB_CLASS}`);
    if (stub && stub.parentElement === historyEl) {
      e.preventDefault();
      setOpen(stub, !stub.classList.contains("open"), { save: true });
      return;
    }
    const stepper = e.target.closest?.("[data-stack-step]");
    if (stepper) {
      e.preventDefault();
      const row = stepper.closest(`.${ROW_CLASS}`);
      if (row && stepper.getAttribute("aria-disabled") !== "true") step(row, Number(stepper.dataset.stackStep));
      return;
    }
    const pick = e.target.closest?.("[data-stack-pick]");
    if (pick) {
      e.preventDefault();
      pick.closest("details")?.removeAttribute("open");
      const target = stubs.get(pick.dataset.stackPick);
      if (!target) return;
      if (!target.classList.contains("open")) setOpen(target, true, { save: false });
      target.scrollIntoView?.({ block: "start", behavior: "smooth" });
      target.focus?.({ preventScroll: true });
      return;
    }
    const button = e.target.closest?.("[data-revise]");
    const row = button?.closest(`.${ROW_CLASS}`);
    if (!button || !row || button.disabled) return;
    e.preventDefault();
    onRevise({ turn_id: button.dataset.revise, label: answerLabel(rowAnswer.get(row)) });
  });

  return { decorate };
}

// The stub that hides +el+ (a superseded turn's element, or inside one),
// opened (not saved); +el+ or null. history_reveal.js runs it on a jump.
export function openStubOver(el) {
  const top = el?.closest?.(`.${HIDDEN_CLASS}`);
  const id = top?.dataset.stackOf;
  const parent = top?.parentElement;
  if (!id || !parent) return el ?? null;
  const stub = [...parent.children].find((c) => c.classList.contains(STUB_CLASS) && c.dataset.stackStub === id);
  stub?.classList.add("open");
  stub?.setAttribute("aria-expanded", "true");
  for (const hidden of parent.querySelectorAll(`:scope > .${HIDDEN_CLASS}`)) {
    if (hidden.dataset.stackOf === id) hidden.classList.remove(HIDDEN_CLASS);
  }
  return el;
}
