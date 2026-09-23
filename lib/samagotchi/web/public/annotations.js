// Annotations: quote a piece of the conversation into the composer.
//
// Selecting text in an answer, a thinking block, a tool row or one of your
// own messages offers "Annotate", which appends a quote block to the
// composer; the note goes under it. The message stays plain text:
//
//   From your thinking:
//   > the quoted line
//
//   the note
//
// The label says where the quote came from. Thinking never reaches the
// model's history, so without it a thinking quote reads as text the model
// never wrote. No DOM state here beyond Element#closest/querySelector, so it
// runs under `node --test` with stand-ins.

// Where a node inside #history came from: { kind, tool, root } where root
// is the element a selection is clipped to, or null when that part of the
// page isn't annotatable (status lines, recaps, cards, a streaming answer).
export function annotationSource(node) {
  const el = node && node.nodeType === 3 ? node.parentElement : node;
  if (!el?.closest) return null;
  const row = el.closest(".activity-row");
  if (row) {
    const tool = row.querySelector(".activity-tool")?.textContent?.trim() || "tool";
    return { kind: "tool", tool, root: row };
  }
  const thinking = el.closest(".thinking-body");
  if (thinking) return { kind: "thinking", root: thinking };
  const own = el.closest(".bubble.user .user-message");
  if (own) return { kind: "user", root: own };
  const answer = el.closest(".bubble.output");
  if (answer && !answer.classList.contains("streaming")) return { kind: "answer", root: answer };
  return null;
}

export function sourceLabel(kind, tool) {
  if (kind === "thinking") return "From your thinking:";
  if (kind === "tool") return `From the ${tool || "tool"} call:`;
  if (kind === "user") return "From my earlier message:";
  return null;
}

// The label and the `>` lines for +text+, ending in a blank line so the note
// starts right under it; null when the selection holds no text.
export function quoteBlock(text, { kind, tool } = {}) {
  const lines = String(text ?? "")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""));
  while (lines.length && !lines[0]) lines.shift();
  while (lines.length && !lines[lines.length - 1]) lines.pop();
  if (!lines.length) return null;
  const label = sourceLabel(kind, tool);
  const quoted = lines.map((l) => (l ? `> ${l}` : ">")).join("\n");
  return `${label ? `${label}\n` : ""}${quoted}\n\n`;
}

// The composer's text with +block+ appended after a blank line.
export function appendQuote(value, block) {
  const before = String(value ?? "").replace(/\s+$/, "");
  return before ? `${before}\n\n${block}` : block;
}
