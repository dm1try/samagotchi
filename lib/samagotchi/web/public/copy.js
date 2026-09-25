// Copy buttons: one on every prompt and answer bubble, one on every code
// block of a rendered answer. An answer copies its markdown source (the
// saved message's `content`, kept on the bubble as data-copy-source when the
// page shows rendered html), a prompt the text as typed, a code block just
// its code.
//
// The buttons carry no text (an icon; "copied ✓" is CSS content), so a
// bubble's textContent, the turn output dedupe and an annotation's selected
// text stay what they were. They are added by one observer on #history, so
// every path that fills it (a render, a live turn in either view, the
// turn-end markdown) gets them without knowing about them.

export const COPY_SOURCE_ATTR = "data-copy-source";

// +text+ to the clipboard; true when it got there. Without the Clipboard
// API (an insecure origin, e.g. chi web on a LAN address) the old way.
export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (_) {
    const area = document.createElement("textarea");
    area.value = text;
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  }
}

// What a bubble copies: its kept source, else its visible text without the
// page's chrome (timing line, badges, labels, the buttons).
const CHROME = ".turn-timing, .state-badge, .origin-label, .thumbs, .copy-btn";

export function bubbleCopyText(bubble) {
  const source = bubble.getAttribute?.(COPY_SOURCE_ATTR);
  if (source !== null && source !== undefined) return source;
  const root = bubble.classList?.contains("user") ? bubble.querySelector(".user-message") || bubble : bubble;
  return visibleText(root, CHROME).replace(/^\s+|\s+$/g, "");
}

// +el+'s text without the subtrees matching +skip+.
export function visibleText(el, skip) {
  let out = "";
  for (const node of el.childNodes || []) {
    if (node.nodeType === 3) out += node.nodeValue;
    else if (node.nodeType === 1 && !(skip && node.matches?.(skip))) out += visibleText(node, skip);
  }
  return out;
}

// A code block's code: the <code> inside it (else the <pre>), without the
// newline the markdown renderer ends every block with.
export function codeText(pre) {
  const code = pre.querySelector?.("code") || pre;
  return visibleText(code, ".copy-btn").replace(/\n$/, "");
}

// The attribute that keeps a message's source on its reloaded bubble:
// rendered html and a prompt (its `>` lines render as quotes) need it; a
// plain answer's text is its source.
export function copySourceAttr(message, renderedMarkdown) {
  if (!renderedMarkdown && message?.role !== "user") return "";
  const text = String(message?.content ?? "")
    .replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return ` ${COPY_SOURCE_ATTR}="${text}"`;
}

const ICON = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M10.5 3.5v-.5A1.5 1.5 0 0 0 9 1.5H3A1.5 1.5 0 0 0 1.5 3v6A1.5 1.5 0 0 0 3 10.5h.5" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>';

const BUBBLES = ".bubble.output:not(.streaming), .bubble.user";
const CODE = ".bubble.output pre";

function makeButton(doc, kind) {
  const btn = doc.createElement("button");
  btn.type = "button";
  btn.className = `copy-btn copy-${kind}`;
  btn.title = kind === "code" ? "Copy code" : "Copy";
  btn.setAttribute("aria-label", btn.title);
  btn.innerHTML = ICON;
  return btn;
}

// Buttons on every bubble and code block in +root+ (and on +root+ itself)
// that has none yet.
export function decorate(root) {
  const doc = root.ownerDocument;
  const bubbles = [...root.querySelectorAll(BUBBLES)];
  if (root.matches(BUBBLES)) bubbles.push(root);
  for (const bubble of bubbles) {
    // First, so the markdown's :last-child margins still see the last block.
    if (!bubble.querySelector(":scope > .copy-btn")) bubble.prepend(makeButton(doc, "bubble"));
  }
  for (const pre of root.querySelectorAll(CODE)) {
    if (pre.parentElement?.classList.contains("code-wrap")) continue;
    const wrap = doc.createElement("div");
    wrap.className = "code-wrap";
    pre.replaceWith(wrap);
    wrap.appendChild(pre);
    wrap.appendChild(makeButton(doc, "code"));
  }
}

// Watch +historyEl+ and answer clicks on its buttons.
export function installCopy(historyEl) {
  // Only what changed is looked at: a streaming bubble rewrites its text
  // every frame, and a long history shouldn't be walked for that.
  const roots = new Set();
  const run = () => {
    const batch = [...roots];
    roots.clear();
    for (const el of batch) if (el.isConnected) decorate(el);
  };
  new MutationObserver((records) => {
    const was = roots.size;
    for (const r of records) {
      if (r.target !== historyEl) roots.add(r.target);
      for (const n of r.addedNodes) if (n.nodeType === 1) roots.add(n);
    }
    if (!was && roots.size) requestAnimationFrame(run);
  }).observe(historyEl, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  decorate(historyEl);

  // A press on a button must not start (or drop) a text selection.
  historyEl.addEventListener("mousedown", (e) => {
    if (e.target.closest?.(".copy-btn")) e.preventDefault();
  });
  historyEl.addEventListener("click", async (e) => {
    const btn = e.target.closest?.(".copy-btn");
    if (!btn) return;
    e.preventDefault();
    e.stopPropagation();
    const text = btn.classList.contains("copy-code")
      ? codeText(btn.parentElement.querySelector("pre"))
      : bubbleCopyText(btn.parentElement);
    if (!(await copyText(text))) return;
    btn.dataset.copied = "1";
    clearTimeout(btn._copiedTimer);
    btn._copiedTimer = setTimeout(() => { delete btn.dataset.copied; }, 1500);
  });
}
