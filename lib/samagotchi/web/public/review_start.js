// Start review (the web's entry points to a review session, docs/sessions.md
// Review sessions): the start page's review files (the ⚙ panel's review
// view, start_settings.js), which make the new session a review session
// (POST /api/sessions {review: {subjects}}), and the session bar's review
// button, a review fork of the open session ({review: {from}}): its recap,
// not its transcript; it keeps running.
import { html, nothing } from "./vendor/lit-html.js";

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

// The files as the form shows them again: a path with a space, a comma or
// a quote in quotes, so readSubjects reads it back whole.
export function formatSubjects(subjects) {
  return (subjects || []).map((s) => (/[\s,"]/.test(s) ? `"${s}"` : s)).join(", ");
}

// The start page's override chip: "review…" with none, else the files' names.
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
// refusal at Start), shown above Set; +text+ the form's text as typed;
// +back+: a ‹ before the heading (data-act="back": the start page's ⚙
// panel, start_settings.js, whose view this is).
export function reviewFormTemplate(subjects, { error = null, text = null, back = false } = {}) {
  return html`<div class="ctx-pop-head">${back ? html`<button type="button" class="sset-back" data-act="back"
    aria-label="Back to the settings" title="Back to the settings">‹</button>` : nothing}<strong>Review</strong><span class="ctx-pop-kind">new session</span
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
