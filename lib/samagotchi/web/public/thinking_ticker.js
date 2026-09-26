// Live thinking as a one-line ticker (web.thinking_ticker): the newest
// complete sentence of the accumulated thinking, changing only at sentence
// boundaries and no sooner than a dwell after the last change. Pure — no DOM,
// no timers. `createTicker` is clock-free: `now` is a getter the caller
// supplies (Date.now() live, a fixed value in the tests) and the caller owns
// the timers (`dueIn` tells when a pending line may show).
//
// Sentence boundary: [.!?…] optionally followed by closing quotes/brackets,
// then whitespace; a newline is also a boundary. Fallback for code-like runs
// without punctuation: a trailing fragment longer than maxLen (160) counts as
// the current sentence (the dwell bounds its churn). Whitespace collapsed to
// single spaces. Abbreviations ("e.g. ") split wrongly — accepted for a ticker.
// A bare list number ("1.", "118.") at the start of a line is a marker, not a
// sentence: the boundary after it is skipped, so the line reads "118. …".
const DEFAULT_MAX_LEN = 160;
const DEFAULT_DWELL_MS = 1500;

// A boundary: either the punctuation (group 1) then a whitespace char or end
// of input, or a bare newline (which is a boundary on its own). Matched on the
// raw text so a newline needs no preceding punctuation; the extracted sentence
// is collapsed afterwards.
const BOUNDARY = /([.!?…][)"'\]]*)(\s|$)|\n/g;
const LIST_MARKER = /^\d{1,4}\.$/;

export function currentSentence(text, { maxLen = DEFAULT_MAX_LEN } = {}) {
  const raw = String(text ?? "");
  if (!raw.trim()) return "";
  let start = 0;
  let sentence = "";
  let found = false;
  let m;
  BOUNDARY.lastIndex = 0;
  while ((m = BOUNDARY.exec(raw)) !== null) {
    const end = m.index + (m[1] ? m[1].length : 0);
    const candidate = raw.slice(start, end);
    // A list number is no sentence: keep reading from the same start.
    if (LIST_MARKER.test(candidate.trim())) continue;
    // Skip an empty sentence (a blank line between two newlines).
    if (candidate.trim()) {
      sentence = candidate;
      found = true;
    }
    start = m.index + m[0].length;
  }
  if (found) return sentence.replace(/\s+/g, " ").trim();
  // No boundary: the trailing fragment counts only if longer than maxLen.
  const fragment = raw.replace(/\s+/g, " ").trim();
  return fragment.length > maxLen ? fragment : "";
}

// A sentence ticker. `feed(text)` computes the newest sentence and, honouring
// the dwell, either shows it now or keeps it pending; `tick()` shows a pending
// line when its dwell has passed; `close()` forgets everything (the caller
// writes the plain label). Each returns { line, changed, dueIn } where dueIn
// is the ms until a pending line may show (0 when nothing pends).
export function createTicker({ now, dwellMs = DEFAULT_DWELL_MS }) {
  let shown = "";
  let pending = null;
  let closed = false;
  let lastChange = typeof now === "function" ? now() : now;

  return {
    feed(text) {
      if (closed) return { line: "", changed: false, dueIn: 0 };
      if (pending !== null && currentSentence(text) === pending) {
        // Still waiting on the dwell; nothing to do.
        return { line: shown, changed: false, dueIn: Math.max(0, dwellMs - (now() - lastChange)) };
      }
      const candidate = currentSentence(text);
      if (!candidate || candidate === shown) {
        return { line: shown, changed: false, dueIn: 0 };
      }
      const elapsed = now() - lastChange;
      // Show now if nothing is shown yet, or the dwell has passed since the
      // last shown change.
      if (shown === "" || elapsed >= dwellMs) {
        shown = candidate;
        pending = null;
        lastChange = now();
        return { line: shown, changed: true, dueIn: 0 };
      }
      // Keep the newest candidate as pending; feed overwrites it.
      pending = candidate;
      return { line: shown, changed: false, dueIn: Math.max(0, dwellMs - elapsed) };
    },
    tick() {
      if (closed) return { line: "", changed: false, dueIn: 0 };
      if (pending !== null && now() - lastChange >= dwellMs) {
        shown = pending;
        pending = null;
        lastChange = now();
        return { line: shown, changed: true, dueIn: 0 };
      }
      return { line: shown, changed: false, dueIn: pending ? Math.max(0, dwellMs - (now() - lastChange)) : 0 };
    },
    close() {
      shown = "";
      pending = null;
      closed = true;
      lastChange = typeof now === "function" ? now() : now;
      return "";
    },
  };
}
