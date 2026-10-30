// The ‹ N/M › switcher on a Revise stack's top answer (revise_stack.js draws
// it in the top answer's row, before the version chip): the owner reads an
// earlier version's answer in place of the top one. View only: no server
// call, nothing stored (a reload shows the latest again).
//
// An earlier version is shown as a copy of its answer bubble (the bubble
// itself stays hidden in its superseded turn): the copy goes just before the
// top answer (its fold row, answer_fold.js, kept with it), and the top answer
// and its fold row are hidden by a class while it shows. The copy keeps its
// kept source (data-copy-source) and its copy buttons, so Copy copies the
// version on view; it has no answer key (data-answer-turn), so no fold row,
// claim key or Revise row is drawn for it, and the top answer stays its
// turn's last answer (verify_target.js, cards_place.js).
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { html } from "./vendor/lit-html.js";

// The copy of an earlier answer on view, and what hides the top one.
export const VIEW_CLASS = "stack-view";
export const SWAPPED_CLASS = "stack-swapped";

// The switcher's words for version +k+ (0-based) of +count+: the counter
// ("2/3") and its spoken label ("version 2 of 3").
export function switchText(k, count) {
  return { text: `${k + 1}/${count}`, label: `version ${k + 1} of ${count}` };
}

// Version +k+ moved by +delta+, kept in 0…count-1.
export function stepVersion(k, count, delta) {
  return Math.min(Math.max(k + delta, 0), Math.max(count - 1, 0));
}

// The switcher for the stack +id+ (its top turn's id) showing version +k+
// of +count+. The buttons stay focusable at either end (aria-disabled, not
// disabled: a press there keeps the focus where it is).
export function switcherTemplate(id, k, count) {
  const { text, label } = switchText(k, count);
  const first = k <= 0;
  const last = k >= count - 1;
  return html`<span class="stack-switch" role="group" aria-label="Answer versions" data-stack-switch=${id}><button type="button" class="stack-switch-btn" data-stack-step="-1" aria-label="Previous version" title="Read the previous version" aria-disabled=${first ? "true" : "false"}>‹</button><span class="stack-switch-n" title=${label}><span aria-hidden="true">${text}</span><span class="stack-switch-sr" aria-live="polite">${label}</span></span><button type="button" class="stack-switch-btn" data-stack-step="1" aria-label="Next version" title="Read the next version" aria-disabled=${last ? "true" : "false"}>›</button></span>`;
}

// A copy of +answer+ (an earlier version's answer bubble) to show in the top
// answer's place, titled as version +version+: no answer key,
// none of the history's state classes.
export function viewOf(answer, version) {
  const view = answer.cloneNode(true);
  for (const attr of ["id", "data-answer-turn", "data-reply-key", "data-stack-of", "data-line-key"]) view.removeAttribute(attr);
  view.classList.remove("stack-hidden", "folded", SWAPPED_CLASS);
  view.classList.add(VIEW_CLASS);
  view.dataset.stackView = String(version);
  for (const btn of view.querySelectorAll(".copy-btn[data-copied]")) delete btn.dataset.copied;
  return view;
}
