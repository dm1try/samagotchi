// Markdown out of the web UI's plain one-line places: the stage's live
// headline (stage_model.js), a closed step's title (turn_model.js
// genLabel), an answered question card's kept-reply line (question_cards.js).
// Pure, no DOM, so `node --test` covers it; the places that render markdown
// (step bodies, the card's open copy) keep the text as written.

// One line as plain text: the markdown a reply carries (headings, quotes,
// bullets and item numbers, table pipes, emphasis, code ticks, links) goes,
// and a line that is only syntax (a code fence, a table's separator row, a
// rule) is empty. A small pass, no renderer: a one-line
// preview only needs to read well, and an unclosed "**" mid-stream goes too.
export function plainLine(line) {
  let s = String(line ?? "").trim();
  if (/^(```|~~~)/.test(s)) return "";
  if (/^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/.test(s)) return "";
  if (/^([-*_])(\s*\1){2,}$/.test(s)) return "";
  s = s.replace(/^(>\s*)+/, "").replace(/^#{1,6}\s+/, "").replace(/^([-*+]|\d{1,9}[.)])\s+(\[[ xX]\]\s+)?/, "");
  // A table row: a pipe at either end (a pipe mid-prose, "a || b", stays).
  if (/^\||\|$/.test(s)) {
    s = s.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim()).filter(Boolean).join(" · ");
  }
  // Code spans keep their text as is; an unclosed tick just goes.
  const code = [];
  s = s.replace(/`+([^`]+)`+/g, (_, c) => `\u0000${code.push(c) - 1}\u0000`);
  s = s
    .replace(/!\[([^\]]*)\]\([^)]*\)?/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)?/g, "$1")
    .replace(/<(https?:\/\/[^>\s]+)>/g, "$1")
    .replace(/`+/g, "")
    .replace(/(^|[^\w])__(?=\S)(.*?\S)__(?=$|[^\w])/g, "$1$2")
    .replace(/(\*\*|~~)/g, "")
    .replace(/(^|[^\w*])\*(?=\S)([^*]*?\S)\*(?=$|[^\w*])/g, "$1$2")
    .replace(/(^|[^\w])_(?=\S)([^_]*?\S)_(?=$|[^\w])/g, "$1$2")
    .replace(/\u0000(\d+)\u0000/g, (_, i) => code[Number(i)]);
  return s.replace(/\s+/g, " ").trim();
}

// A reply as one plain line (each of its lines plainLine's), for a preview
// that clamps it: blank and syntax-only lines go; the lines inside a code
// fence stay as written (code's "*" and "_" are not emphasis), the fences
// themselves go. A line that ends a sentence (or a clause: ":", ",") runs on
// with a space, one that doesn't (a heading, an item) with " · ", so
// "## Plan" and the line under it don't read as one sentence.
export function plainText(text) {
  let out = "";
  let fenced = false;
  for (const raw of String(text ?? "").split("\n")) {
    if (/^\s*(```|~~~)/.test(raw)) { fenced = !fenced; continue; }
    const line = fenced ? raw.trim() : plainLine(raw);
    if (!line) continue;
    if (out) out += /[.!?…:;,]["')\]]*$/.test(out) ? " " : " · ";
    out += line;
  }
  return out;
}
