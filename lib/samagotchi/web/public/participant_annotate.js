// Annotate on the participant page (participant.js): a selection in the
// Plan (the review's subject) or in the thread quotes it into the comment
// box, with where it came from, the way the owner's page does
// (annotations.js, annotate_bar.js):
//
//   From docs/plan.md:
//   > step 3
//
//   Is step 3 safe?
//
// A model reply carries no label (the owner's answers carry none); a
// comment names its author ("From Alex's comment:", "From my earlier
// comment:"). Not annotatable: the reply still streaming, tool rows,
// status lines, time gaps, the header. The bar's source and quote options
// (createAnnotateBar); no DOM state beyond Element#closest, so it runs
// under `node --test` with stand-ins. A module of its own: static JS is
// cached at unversioned URLs, and a new export on an old module would
// blank the page.

import { quoteBlock } from "./annotations.js";

// Where a node on the participant page came from: { kind, root, … } where
// root is the element a selection is clipped to, or null.
//   plan:    { path } the subject shown (#planDoc's data-path)
//   reply:   a model reply's bubble
//   comment: { by, name } a prompt's bubble; by is "me", "participant",
//            "owner" or "automatic" (its .p-msg's data-by), name the
//            participant's (data-name)
export function participantSource(node) {
  const el = node && node.nodeType === 3 ? node.parentElement : node;
  if (!el?.closest) return null;
  const plan = el.closest("#planDoc");
  if (plan) {
    // The "only the first part is shown" note isn't the subject's text.
    if (el.closest(".p-plan-note")) return null;
    return { kind: "plan", path: plan.dataset?.path || "", root: plan };
  }
  const bubble = el.closest(".p-bubble");
  const msg = bubble?.closest(".p-msg");
  if (!msg || msg.classList.contains("live")) return null;
  if (msg.classList.contains("reply")) return { kind: "reply", root: bubble };
  if (msg.classList.contains("user")) {
    return { kind: "comment", by: msg.dataset?.by || "owner", name: msg.dataset?.name || "", root: bubble };
  }
  return null;
}

// The line naming +source+ above the quote, or null (a reply).
export function participantLabel(source) {
  if (source?.kind === "plan") return source.path ? `From ${source.path}:` : "From the plan:";
  if (source?.kind !== "comment") return null;
  if (source.by === "me") return "From my earlier comment:";
  if (source.by === "participant") return `From ${source.name || "a participant"}'s comment:`;
  if (source.by === "automatic") return "From the automatic turn:";
  return "From the owner's message:";
}

// The quote block for the selected +text+ (annotations.js quoteBlock's
// lines) under +source+'s label; null when it holds no text.
export function participantQuote(text, source) {
  const block = quoteBlock(text, { kind: "answer" });
  if (!block) return null;
  const label = participantLabel(source);
  return label ? `${label}\n${block}` : block;
}

// What a message's .p-msg carries for participantSource: data-by and, for
// another participant, data-name. +message+ is a review message (the
// participant route's: mine, author, author_name, automatic).
export function messageAuthorData(message) {
  if (message?.mine) return { by: "me" };
  if (message?.author) return { by: "participant", name: message.author_name || "" };
  if (message?.automatic) return { by: "automatic" };
  return { by: "owner" };
}
