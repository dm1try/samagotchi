// ── Annotate ───────────────────────────────────────────────────────────────
// Selecting text in an answer, thinking, a tool row or an own message shows
// "Annotate" and the presets (web.annotate_presets); Annotate appends the
// quote (with where it came from) to the composer, a preset the quote with
// its text as the note. Nothing is sent. The bar lives outside #history,
// which is re-rendered whole. The selection is read when it changes: a live
// bubble rewrites its text every frame, which would collapse it by the time
// a button is clicked.
//
// A bundle's pills (chi.annotation) come after the presets: each prepares
// its command line with the selection (annotate_actions.js), at most 3
// inline, the rest behind "⋯".
//
// The quoting rules are annotations.js'; this is the bar.

import { annotateBarLeft, annotationSource, quoteBlock } from "./annotations.js";
import { presetNote } from "./annotate_presets.js";
import { actionEnabled, actionTitle, sameActions, selectionFields, splitInline } from "./annotate_actions.js";

// @param presets the preset texts (annotate_presets.js parsePresets)
// @param canAnnotate () => whether the open session takes annotations (one
//   is open and the composer can send)
// @param roots () => the elements a selection may start in (the history,
//   the stage)
// @param isLive (root) => whether a source root is still streaming (refused
//   until its step closes)
// @param onQuote (text) runs with the quote (and a preset's note) to append
//   to the composer; the selection is cleared and the bar hidden first
// @param actions () => the open session's annotation actions
//   (annotate_actions.js annotationActions), read on every selection
// @param running () => whether a turn runs (a send pill may wait for it)
// @param onAction (action, fields) runs with a clicked pill's action and the
//   selection's {quote, text, source}; the selection is cleared and the bar
//   hidden first
// @param doc, win the page's document and window
// @return {schedule(), hide(), el}; schedule() re-reads the selection on the
//   next frame (call it on scroll)
export function createAnnotateBar({
  presets, canAnnotate, roots, isLive, onQuote, actions = () => [], running = () => false, onAction = () => {},
  doc = globalThis.document, win = globalThis.window,
}) {
  const bar = doc.createElement("div");
  bar.id = "annotateBar";
  bar.hidden = true;
  bar.setAttribute("role", "toolbar");
  bar.setAttribute("aria-label", "Annotate");
  function button(text, cls) {
    const btn = doc.createElement("button");
    btn.type = "button";
    btn.className = cls;
    btn.textContent = text;
    return btn;
  }
  bar.appendChild(button("Annotate", "annotate-main"));
  presets.forEach((text, i) => {
    const btn = button(text, "annotate-preset");
    btn.dataset.index = String(i);
    btn.title = text;
    bar.appendChild(btn);
  });
  // The plugin pills: a separator, the inline ones, then ⋯ and the list
  // it opens. Redrawn only when the session's actions change.
  const group = doc.createElement("span");
  group.className = "annotate-actions";
  group.hidden = true;
  bar.appendChild(group);
  doc.body.appendChild(bar);
  let pendingQuote = null;
  let pendingFields = null;
  let drawn = [];
  let moreList = null;

  function drawActions(list) {
    drawn = list;
    moreList = null;
    group.hidden = !list.length;
    if (!list.length) return group.replaceChildren();
    const sep = doc.createElement("span");
    sep.className = "annotate-sep";
    sep.setAttribute("aria-hidden", "true");
    const pill = (action, i) => {
      const btn = button(action.label, "annotate-action");
      btn.dataset.action = String(i);
      if (action.send) btn.dataset.sends = "";
      return btn;
    };
    const { inline, more } = splitInline(list);
    const nodes = [sep, ...inline.map(pill)];
    if (more.length) {
      const toggle = button("⋯", "annotate-more");
      toggle.title = "More actions";
      toggle.setAttribute("aria-label", "More actions");
      moreList = doc.createElement("div");
      moreList.className = "annotate-more-list";
      moreList.hidden = true;
      more.forEach((action, j) => moreList.appendChild(pill(action, inline.length + j)));
      nodes.push(toggle, moreList);
    }
    group.replaceChildren(...nodes);
  }

  // Each pill's state for whether a turn runs (a send pill may wait).
  function markActions() {
    const now = running();
    const all = [...group.children, ...(moreList ? moreList.children : [])];
    for (const btn of all) {
      if (btn.dataset?.action === undefined) continue;
      const action = drawn[Number(btn.dataset.action)];
      btn.disabled = !actionEnabled(action, now);
      btn.title = actionTitle(action, now);
    }
  }

  function hide() {
    pendingQuote = null;
    pendingFields = null;
    if (moreList) moreList.hidden = true;
    bar.hidden = true;
  }

  function update() {
    const sel = win.getSelection();
    if (!canAnnotate() || !sel || sel.isCollapsed || !sel.rangeCount) return hide();
    const range = sel.getRangeAt(0);
    if (!roots().some((root) => root.contains(range.startContainer))) return hide();
    const source = annotationSource(range.startContainer);
    // A running turn's narration box shows complete sentences and its thinking
    // is appended by delta; a selection in either is refused while the step is
    // live — the quote lands once it closes (then on the full text).
    if (!source || isLive(source.root)) return hide();
    // Clip to where the selection starts: one tool row, one bubble.
    const clipped = range.cloneRange();
    if (!source.root.contains(range.endContainer)) clipped.setEnd(source.root, source.root.childNodes.length);
    const raw = clipped.toString();
    const block = quoteBlock(raw, source);
    if (!block) return hide();
    pendingQuote = block;
    pendingFields = selectionFields(raw, source);
    const list = actions() || [];
    if (!sameActions(list, drawn)) drawActions(list);
    markActions();
    const rects = clipped.getClientRects();
    const rect = rects.length ? rects[rects.length - 1] : clipped.getBoundingClientRect();
    bar.hidden = false;
    // Measured at the left edge: a fixed element's shrink-to-fit width is
    // capped by what's right of it, so at the last (right) spot it would
    // measure wrapped.
    bar.style.left = "8px";
    const w = bar.offsetWidth;
    const h = bar.offsetHeight;
    const maxTop = win.innerHeight - h - 8;
    const top = Math.min(rect.bottom + 6, maxTop);
    bar.style.top = `${Math.max(top, 8)}px`;
    bar.style.left = `${annotateBarLeft(rect, w, win.innerWidth)}px`;
    // Not over a copy button (this bubble's, one inside it, the next
    // bubble's).
    const box = bar.getBoundingClientRect();
    const bubble = source.root.closest(".bubble");
    const near = [bubble, bubble?.nextElementSibling].filter(Boolean);
    for (const btn of near.flatMap((el) => [...el.querySelectorAll(".copy-btn")])) {
      const r = btn.getBoundingClientRect();
      if (r.bottom < box.top || r.top > box.bottom || r.right < box.left || r.left > box.right) continue;
      bar.style.top = `${Math.max(Math.min(r.bottom + 4, maxTop), 8)}px`;
      break;
    }
  }

  let raf = false;
  function schedule() {
    if (raf) return;
    raf = true;
    win.requestAnimationFrame(() => { raf = false; update(); });
  }
  doc.addEventListener("selectionchange", schedule);
  win.addEventListener("resize", schedule);
  // Keep the selection when a button is pressed.
  bar.addEventListener("mousedown", (e) => e.preventDefault());
  bar.addEventListener("click", (e) => {
    const btn = e.target.closest("button");
    if (!btn || !pendingQuote) return;
    if (btn.className === "annotate-more") {
      moreList.hidden = !moreList.hidden;
      return;
    }
    if (btn.dataset.action !== undefined) {
      const action = drawn[Number(btn.dataset.action)];
      if (!action || btn.disabled) return;
      const fields = pendingFields;
      win.getSelection()?.removeAllRanges();
      hide();
      onAction(action, fields);
      return;
    }
    const preset = btn.dataset.index === undefined ? null : presets[Number(btn.dataset.index)];
    const text = preset ? presetNote(pendingQuote, preset) : pendingQuote;
    win.getSelection()?.removeAllRanges();
    hide();
    onQuote(text);
  });

  return { schedule, hide, el: bar };
}
