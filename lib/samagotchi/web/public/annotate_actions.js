// Annotation actions: a bundle's pills in the Annotate bar (chi.annotation,
// docs/plugins.md). Each prepares a command line of its plugin with the
// selection filled into its template under it:
//
//   /claude validate
//   From your thinking:
//   > the quoted line
//
// and fills the composer with it (the note goes under), or sends it at once
// (send: true). The pills ride on the session's command listing (the
// worker's snapshot), so a muted bundle's go with its command. Pure: no DOM.
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

import { quoteBlock } from "./annotations.js";

// How many plugin pills the bar shows; the rest go behind "⋯".
const INLINE_ACTIONS = 3;

// The session's commands' annotations, flattened in listing order: {label,
// line, template, send, command, anytime, source}. anytime: the command
// runs mid-turn (a send pill needs it while a turn runs).
export function annotationActions(commands) {
  const out = [];
  for (const c of Array.isArray(commands) ? commands : []) {
    if (!c || typeof c.name !== "string" || !Array.isArray(c.annotations)) continue;
    for (const a of c.annotations) {
      if (!a || typeof a.label !== "string" || !a.label || typeof a.line !== "string" || !a.line) continue;
      out.push({
        label: a.label,
        line: a.line,
        template: typeof a.template === "string" && a.template ? a.template : "{quote}",
        send: a.send === true,
        command: c.name,
        anytime: c.mid_turn === "anytime" || c.anytime === true,
        source: typeof c.source === "string" ? c.source : "",
      });
    }
  }
  return out;
}

// Whether two action lists draw the same pills (the bar redraws only on a
// change).
export function sameActions(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// The selection as templates read it: {quote} the labelled block Annotate
// makes (annotations.js quoteBlock), {text} the selection alone with the
// same trimming (CRLF → LF, each line's trailing blanks, blank lines at
// either end; indentation kept), {source} where it came from (answer,
// thinking, step, tool, user). null when it holds no text.
export function selectionFields(raw, source = {}) {
  const quote = quoteBlock(raw, source);
  if (!quote) return null;
  const lines = String(raw ?? "").replace(/\r\n?/g, "\n").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (lines.length && !lines[0]) lines.shift();
  while (lines.length && !lines[lines.length - 1]) lines.pop();
  return { quote, text: lines.join("\n"), source: source.kind || "answer" };
}

// +template+ with {quote}, {text} and {source} filled from +fields+; any
// other {x} stays as written.
export function fillTemplate(template, fields) {
  return String(template ?? "").replace(/\{(quote|text|source)\}/g, (_, key) => String(fields?.[key] ?? ""));
}

// The line the pill prepares: its command line, the filled template under it.
export function actionLine(action, fields) {
  return `${action.line}\n${fillTemplate(action.template, fields)}`;
}

// The composer's text after a fill pill (+line+: actionLine's):
//   - empty: the line;
//   - it already starts with the same command line: the filled part is
//     appended (several selections collect under one command);
//   - another draft: the line on top, the draft under it, after a blank line
//     (nothing leaves chi without a click on Send).
export function composerWithAction(value, action, line) {
  const draft = String(value ?? "");
  if (!draft.trim()) return line;
  const filled = line.slice(action.line.length + 1);
  if (draft.trimStart().split("\n")[0].trim() === action.line) {
    const before = draft.replace(/\s+$/, "");
    return `${before}\n\n${filled}`;
  }
  return `${line.replace(/\s+$/, "")}\n\n${draft.replace(/^\s*\n/, "")}`;
}

// Whether a pill can be clicked: a fill pill always; a send pill while a
// turn runs only when its command runs mid-turn (anytime), else it would come
// back busy.
export function actionEnabled(action, running) {
  return !action.send || !running || action.anytime;
}

// A pill's tooltip: its label and bundle, that a send pill sends at once,
// and why it is disabled.
export function actionTitle(action, running) {
  const base = action.source ? `${action.label} (${action.source})` : action.label;
  if (!actionEnabled(action, running)) return `${base}: ${action.command} waits for the turn to end`;
  return action.send ? `${base}: sends at once` : base;
}

// The pills shown inline and the ones behind "⋯".
export function splitInline(actions, max = INLINE_ACTIONS) {
  return { inline: actions.slice(0, max), more: actions.slice(max) };
}
