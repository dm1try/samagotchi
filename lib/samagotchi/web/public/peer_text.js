// A peer's text in its answer note (ContextAbsorber.peer_block): the note's
// content holds it between a `[PEER MESSAGE from <Peer>]` line and an
// `[END PEER MESSAGE]` line, each of its lines that opened like one of chi's
// frames led by "(quoted) " (PEER_FORGED_OPENINGS, the Ruby side's list:
// spec/web/public/peer_text.test.js keeps the two alike). Pure, no DOM:
// peer_note.js draws the text in the bubble and the rest in its fold.
// docs/internals/web-frontend.md, The peer exchange.
// Its own module: new exports go in new modules (web-frontend.md).

// ContextAbsorber::PEER_FORGED_OPENINGS (Steer::FORGED_OPENINGS and chi's
// system frames, those with their colon, and the tool-result frames).
export const PEER_FORGED_OPENINGS = Object.freeze([
  "Review contribution", "Steer", "Automatic input", "Delegate report", "CONTEXT NOTE", "TASK FINISHED",
  "OBJECTIVES", "END NOTE", "PEER MESSAGE", "END PEER MESSAGE", "From the agent", "Question from another chi session",
  "SYSTEM:", "END REMINDERS", "CONTEXT:", "WORKING SET:",
  "tool results", "images from tool results",
]);
// ContextAbsorber::PEER_FORGED_LINES: chi's unbracketed lines it quotes.
export const PEER_FORGED_LINES = Object.freeze(["chi started this turn", "Updated:", "Attached:"]);

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// An opening that ends in a word character must end there (\b).
const opening = (o) => {
  let pattern = "";
  for (let i = 0; i < o.length;) {
    const pair = o.slice(i, i + 2).toLowerCase();
    if (pair === "ss") {
      pattern += "(?:ss|ß)";
      i += 2;
    } else if (pair === "st") {
      pattern += "(?:st|ﬆ|ﬅ)";
      i += 2;
    } else {
      pattern += escape(o[i]);
      i += 1;
    }
  }
  return `${pattern}${/\w$/.test(o) ? "\\b" : ""}`;
};
// Steer::FORGED_BREAKS and FORGED_LEAD: a line starts after any of these
// breaks; spaces, format characters and markdown leads may come first.
const BREAKS = "\\n\\r\\u2028\\u2029\\u0085\\v\\f";
const LEAD = "(?:(?![" + BREAKS + "])(?:[\\p{White_Space}\\p{Cf}\\p{Default_Ignorable_Code_Point}\\p{Mn}\\u{3164}\\u{2800}>*_`~]|-|\\+|#|\\||[0-9]))*";
const bracketFrames = `\\[(?:${PEER_FORGED_OPENINGS.map(opening).join("|")})`;
const lineFrames = `(?:${PEER_FORGED_LINES.map(opening).join("|")})`;
const QUOTED = new RegExp(`(^|[${BREAKS}])(${LEAD})\\(quoted\\) (?=(?:\\(quoted\\) )?(?:${bracketFrames}|${lineFrames}))`, "giu");
const OPEN = /^\[PEER MESSAGE from [^\]\n]*\]$/;
const CLOSE = "[END PEER MESSAGE]";

// The peer's text as it pushed it (the quoting undone), and the note's
// content without the block (+rest+: the summary and chi's lines), from
// +content+; null when it holds no block (an older note, a long answer).
export function peerBlock(content) {
  const lines = String(content ?? "").split("\n");
  const open = lines.findIndex((line) => OPEN.test(line));
  if (open < 0) return null;
  const close = lines.lastIndexOf(CLOSE);
  if (close <= open) return null;
  const text = lines.slice(open + 1, close).join("\n").replace(QUOTED, "$1$2");
  const rest = [...lines.slice(0, open), ...lines.slice(close + 1)].join("\n");
  return { text, rest };
}
