// Sentence scanning for the live views (the thinking ticker, the narration
// box). Pure — no DOM, no timers.
//
// Sentence boundary: [.!?…] optionally followed by closing quotes/brackets,
// then whitespace; a newline is also a boundary. The end of the input counts
// as a boundary only when the caller says so (`atEnd`): a ticker shows the
// newest sentence and corrects itself next frame, an append-only box cannot
// take "version 3." back once "version 3.5" streams in. Whitespace is
// collapsed to single spaces. Abbreviations ("e.g. ") split wrongly —
// accepted for a live view. A bare list number ("1.", "118.") at the start
// of a line is a marker, not a sentence: the boundary after it is skipped,
// so the line reads "118. …".
export const DEFAULT_MAX_LEN = 160;

// A boundary: the punctuation (group 1) then a whitespace char (or the end
// of input), or a bare newline (a boundary on its own). Matched on the raw
// text so a newline needs no preceding punctuation.
const BOUNDARY = /([.!?…][)"'\]]*)(\s|$)|\n/g;
const BOUNDARY_NOT_AT_END = /([.!?…][)"'\]]*)(\s)|\n/g;
const LIST_MARKER = /^\d{1,4}\.$/;

function collapse(s) {
  return s.replace(/\s+/g, " ").trim();
}

// Every complete sentence in +raw+ (collapsed, blanks skipped), the trailing
// raw fragment and the index where it starts.
export function splitSentences(text, { atEnd = false } = {}) {
  const raw = String(text ?? "");
  const re = atEnd ? BOUNDARY : BOUNDARY_NOT_AT_END;
  const sentences = [];
  let start = 0;
  let m;
  re.lastIndex = 0;
  while ((m = re.exec(raw)) !== null) {
    const end = m.index + (m[1] ? m[1].length : 0);
    const candidate = raw.slice(start, end);
    // A list number is no sentence: keep reading from the same start.
    if (LIST_MARKER.test(candidate.trim())) continue;
    const collapsed = collapse(candidate);
    // Skip an empty sentence (a blank line between two newlines).
    if (collapsed) sentences.push(collapsed);
    start = m.index + m[0].length;
  }
  return { sentences, rest: raw.slice(start), restStart: start };
}

// A feed over an accumulating text: `feed(text)` returns the sentences
// completed since the last call (the end of the text is no boundary; a
// trailing fragment longer than maxLen is cut as a sentence — code-like runs
// without punctuation); `flush(text)` returns what is left, the remainder as
// one collapsed sentence, and consumes it; `reset()` starts over. A text
// shorter than what was consumed (a reset upstream) resyncs and yields [].
export function createSentenceFeed({ maxLen = DEFAULT_MAX_LEN } = {}) {
  let consumed = 0;

  function scan(text, atEnd) {
    const raw = String(text ?? "");
    if (raw.length < consumed) { consumed = raw.length; return null; }
    const r = splitSentences(raw.slice(consumed), { atEnd });
    consumed += r.restStart;
    return { ...r, total: raw.length };
  }

  return {
    feed(text) {
      const r = scan(text, false);
      if (!r) return [];
      const fragment = collapse(r.rest);
      if (fragment.length > maxLen) {
        r.sentences.push(fragment);
        consumed = r.total;
      }
      return r.sentences;
    },
    flush(text) {
      const r = scan(text, true);
      if (!r) return [];
      const fragment = collapse(r.rest);
      if (fragment) r.sentences.push(fragment);
      consumed = r.total;
      return r.sentences;
    },
    reset() {
      consumed = 0;
    },
  };
}
