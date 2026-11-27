// The answer's live write onto its bubble: the markdown class, copy source,
// display flag, html and hover time (the same four writes as a reload's
// answerBubbleTemplate, minus the at/turn/reply-key the live bubble already
// has). A new module for the one reason it exists: static JS is cached at
// unversioned URLs, so a tab or proxy can hold an OLD answer_refs.js while
// loading the NEW caller (markdown_place.js, block_fix.js); a new export on
// an old module would blank the page, an import of a new module would not.
// Not the refs: answer_refs.js sets them (a module of its own: it would
// import the other).

import { COPY_SOURCE_ATTR, copySource } from "./copy.js";
import { fullTime } from "./format.js";

// The answer written onto +bubble+ (the live bubble, which has its data-
// answer-at, data-answer-turn and data-reply-key already and keeps them).
// Only the html branch: with web.markdown off or no renderer the text stays.
export function writeAnswer(bubble, message) {
  if (typeof message.html !== "string") return;
  bubble.classList.add("markdown");
  bubble.setAttribute(COPY_SOURCE_ATTR, copySource(message));
  // A hook's display in the answer's place (answer_fold.js's label).
  bubble.toggleAttribute("data-answer-display", typeof message.display === "string");
  // The server's rendered markdown, sanitized there (Web::MarkdownRenderer#sanitize): set as it is, not templated.
  bubble.innerHTML = message.html;
  // The full hover time (turn_html.js's timeTitle is lit's: a string here).
  const title = fullTime(message.at);
  if (title) bubble.setAttribute("title", title);
}
