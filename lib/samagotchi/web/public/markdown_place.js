// Where the page's rendered markdown and its refs go (moved out of app.js):
// a text as its markdown HTML, the `path:line` refs in one rendered text,
// a final answer's rendering and refs, and the refs across the page. The
// page's state comes in as getters (capabilities, roots, currentDir), read
// at each call.

// The texts whose refs linkTextRefs links: the answers and the closed
// steps' texts.
const TEXTS = ".bubble.output, .gen:not(.live) > .gen-text";
// The closed steps' texts still shown raw: a live turn's (a reload's come
// rendered, turn_view.js textTemplate).
const RAW_STEPS = ".gen:not(.live) > .gen-text:not(.markdown)";

export function createMarkdownPlace({
  capabilities, renderText, roots, touchedFiles, currentDir, linkRefs, applyFinalAnswer, findInTurnRoots, normalize,
  pairAnswerRefs, setAnswerRefs = () => {}, answerRefsOf = () => null,
}) {
  // The raw step texts already waiting for their step's open.
  const waiting = new WeakSet();

  // A text the page already shows as its markdown HTML (POST /api/render,
  // sanitised there), or null: markdown off here (no request), or a failed
  // read (the raw text stays).
  function renderMarkdown(text) {
    if (capabilities().display !== true) return Promise.resolve(null);
    return renderText(text)
      .then((d) => (typeof d?.html === "string" && d.html ? d.html : null))
      .catch(() => null);
  }

  // A plugin's +refs+ (a question's: its pending question's refs) paired
  // with one shown text (answer_refs.js), again after each swap of its
  // nodes: setAnswerRefs starts the pairing over. Not +refs+: nothing.
  function pairRefsIn(el, refs) {
    if (refs === undefined || refs === null) return;
    setAnswerRefs(el, refs);
    pairAnswerRefs(el);
  }

  // The refs in one rendered text (the stage's asking slot, a kept reply),
  // as linkTextRefs links the answers': a plugin's +refs+ first
  // (pairRefsIn), then the `path:line` ones.
  function linkRefsIn(el, refs) {
    pairRefsIn(el, refs);
    linkRefs(el, touchedFiles(roots()), currentDir());
  }

  // The turn's answer as its rendered markdown and with its plugin refs,
  // once it is final (the turn-end read, an answer_display re-read:
  // answer_refs.js applyFinalAnswer); then the refs.
  function applyFinalMarkdown(messages) {
    applyFinalAnswer(messages, findInTurnRoots(".bubble.output"), normalize);
    linkTextRefs();
  }

  // The refs on the answers' and closed steps' texts, on this page: first
  // each one's own (a plugin's, answer_refs.js: a step's are a question's,
  // on the reply that asked it), then the `path:line`
  // refs that name a file the session's rows (and cards) touched
  // (ref_scan.js), which leave a plugin's alone. Not mid-stream: at a
  // turn's end and after a reload's render. A ref already made stays as it
  // is.
  function linkTextRefs() {
    renderStepTexts();
    const pageRoots = roots();
    const touched = touchedFiles(pageRoots);
    for (const root of pageRoots) {
      for (const el of root.querySelectorAll(TEXTS)) pairAnswerRefs(el);
    }
    if (!touched.size) return;
    for (const root of pageRoots) {
      for (const el of root.querySelectorAll(TEXTS)) linkRefs(el, touched, currentDir());
    }
  }

  // The closed steps' raw texts as markdown, as the answers' (markdown on
  // only): each from its step's first open (a turn's end would ask once per
  // step, folded or not), as a resolved question card's kept reply. The
  // text stays as its source (stepText); its refs, a question's, pair again
  // on the swap, then the `path:line` ones (linkRefsIn). A null render
  // keeps the text, and the next open asks again.
  function renderStepTexts() {
    if (capabilities().display !== true) return;
    for (const root of roots()) {
      for (const el of root.querySelectorAll(RAW_STEPS)) {
        const step = el.parentElement;
        if (waiting.has(el) || !step?.addEventListener) continue;
        waiting.add(el);
        renderOnOpen(step, el, el.textContent);
      }
    }
  }

  function renderOnOpen(step, el, text) {
    let state = "raw";
    const draw = () => {
      if (!step.open || state !== "raw") return;
      state = "asking";
      renderMarkdown(text).then((html) => {
        if (!html || el.textContent !== text) { state = html ? "done" : "raw"; return; }
        state = "done";
        step.removeEventListener("toggle", draw);
        const refs = answerRefsOf(el);
        el.setAttribute("data-copy-source", text);
        // Sanitised on the server (POST /api/render).
        el.innerHTML = html;
        el.classList.add("markdown", "md-compact");
        linkRefsIn(el, refs);
      });
    };
    step.addEventListener("toggle", draw);
    draw();
  }

  return { renderMarkdown, pairRefsIn, linkRefsIn, applyFinalMarkdown, linkTextRefs };
}
