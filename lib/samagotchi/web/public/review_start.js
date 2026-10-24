// Start review (the web's entry points to a review session, docs/sessions.md
// Review sessions): the start page's review chip, whose files make the new
// session a review session (POST /api/sessions {review: {subjects}}), and the
// session bar's review button, a review fork of the open session
// ({review: {from}}): its recap, not its transcript; it keeps running.
import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";

// The files typed: split on commas, spaces and new lines, no repeats; a
// path with a space (or a comma) in double quotes ("docs/my plan.md").
// @return {subjects, error}: error, a quote left open (then no subjects)
export function readSubjects(text) {
  const found = [];
  for (const m of String(text || "").matchAll(/"([^"]*)("?)|[^\s,"]+/g)) {
    if (m[1] !== undefined && !m[2]) return { subjects: [], error: `A quote isn't closed: "${m[1].trim()}` };
    const path = (m[1] ?? m[0]).trim();
    if (path) found.push(path);
  }
  return { subjects: [...new Set(found)], error: null };
}

export const parseSubjects = (text) => readSubjects(text).subjects;

// The files as the form shows them again: a path with a space, a comma or
// a quote in quotes, so parseSubjects reads it back whole.
export function formatSubjects(subjects) {
  return (subjects || []).map((s) => (/[\s,"]/.test(s) ? `"${s}"` : s)).join(", ");
}

// The start page's chip: "review…" with none, else the files' names.
export function reviewChipModel(subjects) {
  const list = subjects || [];
  if (!list.length) {
    return { text: "review…", own: false, title: "Start a review session instead: pick the project files participants will read beside the thread" };
  }
  const names = list.map((s) => s.split("/").pop());
  return { text: `review: ${names[0]}${names.length > 1 ? ` +${names.length - 1}` : ""}`, own: true,
           title: `A review session of ${list.join(", ")}: Start makes it (your message, if any, is its first turn); then invite someone from the participants chip` };
}

// +error+: why the files weren't taken (a quote left open, the server's
// refusal at Start), shown above Set; +text+ the form's text as typed.
export function reviewFormTemplate(subjects, { error = null, text = null } = {}) {
  return html`<div class="ctx-pop-head"><strong>Review</strong><span class="ctx-pop-kind">new session</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
    <div class="ctx-pop-meta" id="reviewNewHelp">The files participants read beside the thread: project paths, relative to this folder,
      a path with a space in quotes. Secrets (.env, keys) and files outside the project are refused.</div>
    <form class="rs-form"><textarea name="subjects" rows="2" placeholder="docs/plan.md, docs/spec.md" aria-label="Files to review"
      aria-describedby="reviewNewHelp" aria-invalid=${error ? "true" : "false"}
      autocomplete="off" spellcheck="false" .value=${text ?? formatSubjects(subjects)}></textarea>
      <div class="ctx-pop-error" role="alert" ?hidden=${!error}>${error || ""}</div>
      <div class="ctx-pop-actions">${subjects?.length ? html`<button type="button" data-act="clear">No review</button>` : nothing}<button
        type="submit">Set</button></div></form>`;
}

// The start page's chip and its form. +el+ the chip; +choose(subjects)+.
// refuse(message): Start's refusal of the files (400 invalid_review), said
// in the form, opened again at the files chosen.
export function createReviewStartControl({ el, choice, choose, doc = document, win = window }) {
  let error = null;
  let text = null;
  const draw = () => {
    render(reviewFormTemplate(choice(), { error, text }), shell.pop);
    shell.replace();
  };
  const shell = createChipPopover({
    id: "reviewNewPopover", className: "ctx-popover review-popover", width: 360, el, anchor: `#${el.id}`,
    summary: () => ({}), sheet: true, doc, win,
    show: () => {
      draw();
      shell.pop.querySelector("textarea")?.focus();
    },
    onClose: () => { error = null; text = null; },
    onSubmit: (form) => {
      const typed = form.elements.subjects?.value || "";
      const read = readSubjects(typed);
      if (read.error) {
        error = read.error;
        text = typed;
        return draw();
      }
      choose(read.subjects);
      shell.close();
    },
    onAct: (name) => {
      if (name === "clear") {
        choose([]);
        shell.close();
      }
    },
  });
  return {
    close: () => shell.close(),
    refuse: (message) => {
      error = message;
      text = null;
      if (shell.isOpen()) draw();
      else shell.open(el);
    },
  };
}
