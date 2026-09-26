// Live thinking as a one-line ticker (web.thinking_ticker): the newest
// complete sentence of the accumulated thinking, changing only at sentence
// boundaries and no sooner than a dwell after the last change. Pure — no DOM,
// no timers. `createTicker` is clock-free: `now` is a getter the caller
// supplies (Date.now() live, a fixed value in the tests) and the caller owns
// the timers (`dueIn` tells when a pending line may show).
//
// The sentence boundary rule lives in sentences.js (shared with the
// narration box). Fallback for code-like runs without punctuation: a
// trailing fragment longer than maxLen (160) counts as the current sentence
// (the dwell bounds its churn).
import { DEFAULT_MAX_LEN, splitSentences } from "./sentences.js";

const DEFAULT_DWELL_MS = 1500;

// The newest complete sentence of +text+ (the end of the text counts as a
// boundary: the ticker corrects itself next frame), else the trailing
// fragment when longer than maxLen, else "".
export function currentSentence(text, { maxLen = DEFAULT_MAX_LEN } = {}) {
  const { sentences, rest } = splitSentences(text, { atEnd: true });
  if (sentences.length) return sentences[sentences.length - 1];
  const fragment = rest.replace(/\s+/g, " ").trim();
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
