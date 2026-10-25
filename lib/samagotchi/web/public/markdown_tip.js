// The session view's Markdown tip (the server's Web::MarkdownRenderer#tip,
// sent as markdown_tip while web.markdown is off): one calm line with a ×
// that hides it for this browser. The text is the server's; an older server
// sends none, so no tip.
import { readStored, writeStored } from "./storage.js";

export const TIP_DISMISSED_KEY = "chi_markdown_tip_dismissed";

// +el+ holds a .markdown-tip-text span and a .markdown-tip-close button
// (index.html's #markdownTip).
export function createMarkdownTip(el) {
  const textEl = el.querySelector(".markdown-tip-text");
  const closeBtn = el.querySelector(".markdown-tip-close");

  function hide() {
    el.hidden = true;
    textEl.textContent = "";
  }

  // The tip for this payload: shown unless there is none or it was dismissed.
  function show(text) {
    if (!text || readStored(TIP_DISMISSED_KEY) === "1") return hide();
    textEl.textContent = text;
    el.hidden = false;
  }

  closeBtn.addEventListener("click", () => {
    writeStored(TIP_DISMISSED_KEY, "1");
    hide();
  });

  return { show };
}
