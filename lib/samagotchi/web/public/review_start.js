// Start review (the web's entry points to a review session, docs/sessions.md
// Review sessions): the start page's review chip, whose files make the new
// session a review session (POST /api/sessions {review: {subjects}}), and the
// session bar's review button, a review fork of the open session
// ({review: {from}}): its recap, not its transcript; it keeps running.
import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";

// The files typed: split on commas, spaces and new lines, no repeats.
export function parseSubjects(text) {
  return [...new Set(String(text || "").split(/[\s,]+/).map((s) => s.trim()).filter(Boolean))];
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

export function reviewFormTemplate(subjects) {
  return html`<div class="ctx-pop-head"><strong>Review</strong><span class="ctx-pop-kind">new session</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
    <div class="ctx-pop-meta">The files participants read beside the thread: project paths, relative to this folder.
      Secrets (.env, keys) and files outside the project are refused.</div>
    <form class="rs-form"><textarea name="subjects" rows="2" placeholder="docs/plan.md, docs/spec.md" aria-label="Files to review"
      autocomplete="off" spellcheck="false" .value=${(subjects || []).join(", ")}></textarea>
      <div class="ctx-pop-actions">${subjects?.length ? html`<button type="button" data-act="clear">No review</button>` : nothing}<button
        type="submit">Set</button></div></form>`;
}

// The start page's chip and its form. +el+ the chip; +choose(subjects)+.
export function createReviewStartControl({ el, choice, choose, doc = document, win = window }) {
  const shell = createChipPopover({
    id: "reviewNewPopover", className: "ctx-popover review-popover", width: 360, el, anchor: `#${el.id}`,
    summary: () => ({}), sheet: true, doc, win,
    show: () => {
      render(reviewFormTemplate(choice()), shell.pop);
      shell.replace();
      shell.pop.querySelector("textarea")?.focus();
    },
    onSubmit: (form) => {
      choose(parseSubjects(form.elements.subjects?.value));
      shell.close();
    },
    onAct: (name) => {
      if (name === "clear") {
        choose([]);
        shell.close();
      }
    },
  });
  return { close: () => shell.close() };
}
