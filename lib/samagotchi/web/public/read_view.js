// A read row's output as the file's lines, numbered (a lit-html template).
// Only when the output is the file text as-is: each numbered line is a
// ref's line (refs.js opens the row's file there). The row's preview
// (turn_html.js) strips any "[tag] " and cuts at 300 chars; numbering
// needs the text exactly as read, so it is drawn on its own, closed.

import { html, nothing } from "./vendor/lit-html.js";

// What follows one of these isn't the file's next line: a ToolRunner cap
// ("[cut: …]"), a head/tail preview's gap ("[... omitted …]") or the note
// of a range clamped at the end of the file ("[read: end_line …]"). They
// are appended at the end (a clamp note, then a cut), so only the last
// MARKER_LINES lines can be one: such a line earlier is the file's own.
const MARKER_LINES = 2;
const MARKER = /^(?:\[cut: |\[\.\.\. omitted |\[read: end_line \d+ exceeds )/;

// An image's line instead of its text: attached, or why not (ToolRunner).
const IMAGE = /\((?:\d+×\d+ )?[A-Z]+\)(?: attached\.| is an image; | is not attached: )/;

// The file text of a read row's output, or null when it isn't the file
// as-is: an error, the head/tail preview of a big file, an image's line.
function fileText(row) {
  if (row?.tool !== "read" || row.status !== "ok" || row.ref?.kind !== "file" || row.images?.length) return null;
  let text = String(row.output || "");
  // The call the gate replaced says so on a line before the tag.
  if (text.startsWith("ran as: ")) text = text.slice(text.indexOf("\n") + 1);
  if (!text.startsWith("[read]\n")) return null;
  text = text.slice("[read]\n".length);
  if (!text || text.startsWith("Error: ") || text.startsWith("truncated=true\n")) return null;
  if (!text.includes("\n") && IMAGE.test(text)) return null;
  return text;
}

// @return {null | Array<{text, line}>} the output's lines, line null for
// one that isn't the file's: a marker and all after it, and the "…" of a
// reload's capped output (output_truncated; a cut line already says so
// for a live one). The first line is the range's start_line (the ref's
// line), else 1.
export function readLines(row) {
  const text = fileText(row);
  if (text === null) return null;
  const lines = text.split("\n");
  // The file's last newline ends a line, it doesn't start one.
  if (lines.at(-1) === "") lines.pop();
  let next = Number(row.ref.line) || 1;
  let numbering = true;
  const out = [];
  lines.forEach((line, i) => {
    if (numbering && i >= lines.length - MARKER_LINES && MARKER.test(line)) {
      numbering = false;
      // The newline before a marker is the marker's: the blank it leaves
      // isn't a line of the file.
      if (i > 0 && lines[i - 1] === "" && out.at(-1)?.line !== null) out.pop();
    }
    out.push({ text: line, line: numbering ? next++ : null });
  });
  if (row.output_truncated && numbering) out.push({ text: "…", line: null });
  return out;
}

// A read row's numbered lines behind a closed toggle ("lines 40–60");
// nothing when its output isn't the file as-is. lit never binds its open:
// a user's toggle stays across a redraw.
export function readLinesTemplate(row) {
  const lines = readLines(row);
  const numbered = lines?.filter((l) => l.line !== null) || [];
  if (!numbered.length) return nothing;
  const first = numbered[0].line;
  const last = numbered.at(-1).line;
  const label = first === last ? `line ${first}` : `lines ${first}–${last}`;
  // A blank line of the file holds no text, only a <br>: an empty block
  // drops out of a copied selection, a space would be copied as one.
  const spans = lines.map(({ text, line }) => line === null
    ? html`<span class="read-line read-meta">${text}</span>`
    : html`<span class="read-line" data-line=${line}>${text || html`<br>`}</span>`);
  return html`<details class="activity-read"><summary>${label}</summary><pre class="read-lines"><code>${spans}</code></pre></details>`;
}
