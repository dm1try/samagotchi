// Annotate presets: quick replies next to "Annotate" in the selection bubble
// (web.annotate_presets, "Agreed|Could you please elaborate?"). A preset
// fills the composer with the quote and its text as the note; it never
// sends. Its own module, not more exports on annotations.js: static files
// are cached at unversioned URLs, and a fresh app.js importing a missing
// export from a cached annotations.js would fail to link.

export const MAX_PRESETS = 5;

// The presets in +raw+ ("a|b|c"): trimmed, blanks and repeats dropped, at
// most MAX_PRESETS. A preset can't hold "|".
export function parsePresets(raw) {
  const out = [];
  for (const part of String(raw ?? "").split("|")) {
    const text = part.trim();
    if (text && !out.includes(text)) out.push(text);
    if (out.length === MAX_PRESETS) break;
  }
  return out;
}

// The quote +block+ (from quoteBlock, ending in a blank line) with +text+
// as its note.
export function presetNote(block, text) {
  return `${block}${text}`;
}
