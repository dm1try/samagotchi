// The line under a block that failed to draw, as a fix is asked for or not
// (block_fix.js; docs/internals/block-renderers.md, A failed block is asked for
// again). DOM only. It is failBlock's own .block-note (block_watch.js): its words
// stay an attribute CSS shows, and a button in it has its label drawn by CSS from
// data-label with an aria-label, no text node, so nothing of the page's own gets
// into a bubble's textContent (copy.js's rule). A click on the words still copies
// them (the watcher's listener); a click on a button is the button's.
//
// The states (data-fix on the line):
//   asking   "… · asking for a fix…" and a pulsing dot
//   nohelp   "… · a fix didn't help", Ask in chat
//   again    "…, also after a fix: reason", Ask in chat (a fixed block failing again)
//   older    today's words, Ask in chat (an older answer, or past its 2 blocks)
//   restart  "… · restart this session to fix" (a worker without the feature)
//   today    today's words, no button (a failure that isn't the model's)
// A fixed block that draws gets its own line after it: "Drawn after a fix".
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

import { figureOf } from "./block_source.js";

export const ASK_LABEL = "Ask in chat";
export const FIXED_TEXT = "Drawn after a fix";
const ASK = "block-fix-ask";
const FIXED = "fixed";

// The failed block's line (failBlock puts it right after the <pre>), or null.
export function noteOf(pre) {
  const next = pre?.nextElementSibling;
  return next?.classList?.contains("block-note") && !next.classList.contains(FIXED) ? next : null;
}

// What failBlock said: "Couldn't draw this <lang> block: <first line>".
function baseWords(lang, reason) {
  const first = String(reason ?? "").split("\n")[0].trim();
  return `Couldn't draw this ${lang} block${first ? `: ${first}` : ""}`;
}

function words(state, lang, reason) {
  const base = baseWords(lang, reason);
  switch (state) {
    case "asking": return `${base} · asking for a fix…`;
    case "nohelp": return `${base} · a fix didn't help`;
    case "again": {
      const first = String(reason ?? "").split("\n")[0].trim();
      return `Couldn't draw this ${lang} block, also after a fix${first ? `: ${first}` : ""}`;
    }
    case "restart": return `${base} · restart this session to fix`;
    default: return base;
  }
}

const WITH_ASK = new Set(["nohelp", "again", "older"]);

// Sets the failed block's line to +state+. Returns the line, or null when the
// block has none (it drew, or left the page).
export function setFixNote(pre, state, { lang = pre?.getAttribute?.("data-lang") || "", reason = pre?.dataset?.blockReason } = {}) {
  const note = noteOf(pre);
  if (!note) return null;
  const text = words(state, lang, reason);
  note.dataset.text = text;
  note.setAttribute("aria-label", text);
  if (state === "today") delete note.dataset.fix;
  else note.dataset.fix = state;
  let button = note.querySelector(`:scope > .${ASK}`);
  if (WITH_ASK.has(state) && !button) {
    button = note.ownerDocument.createElement("button");
    button.type = "button";
    button.className = ASK;
    button.dataset.label = ASK_LABEL;
    button.setAttribute("aria-label", ASK_LABEL);
    note.append(button);
  } else if (!WITH_ASK.has(state) && button) {
    button.remove();
  }
  return note;
}

// The sentence Ask in chat puts in the composer (never sent).
export function askText(lang, reason) {
  const first = String(reason ?? "").split("\n")[0].trim().replace(/[.\s]+$/, "");
  return `The ${lang} block in your answer didn't draw${first ? `: ${first}` : ""}. Please send it again, corrected.`;
}

// "Drawn after a fix" under a fixed block that drew (data-block-fixed and a
// figure), gone when it failed after all. Idempotent.
export function markFixed(pre) {
  let mark = null;
  for (let at = pre.nextElementSibling; at?.classList?.contains("block-note"); at = at.nextElementSibling) {
    if (at.classList.contains(FIXED)) { mark = at; break; }
  }
  const wanted = pre.hasAttribute("data-block-fixed") && !!figureOf(pre) && !pre.dataset.blockFailed;
  if (wanted && !mark) {
    const line = pre.ownerDocument.createElement("div");
    line.className = `block-note ${FIXED}`;
    line.dataset.text = FIXED_TEXT;
    line.setAttribute("role", "note");
    line.setAttribute("aria-label", FIXED_TEXT);
    pre.after(line);
  } else if (!wanted && mark) {
    mark.remove();
  }
}
