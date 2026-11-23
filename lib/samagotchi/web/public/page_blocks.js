// A page's blocks as lit templates (docs/pages.md): a text block as the
// server's sanitised html (Markdown on) or as plain text with its line
// breaks, a walk in a widget host drawn by drawWalk (inline_widgets.js'
// shadow root and sheet), a table by +table+ (page_table.js), and a block of
// a type this page doesn't know (a newer chi's) as one muted line, never a
// blank or a throw. What a script wrote reaches the page as text or
// attributes only; the one markup is the server's sanitised html. A fenced
// block inside a text block stays source: no block watcher runs here.
import { html, nothing } from "./vendor/lit-html.js";
import { unsafeHTML } from "./vendor/directives/unsafe-html.js";
import { HOST, loadWidgetSheet } from "./inline_widgets.js";
import { drawWalk } from "./widget_walk.js";

// The class a walk's host carries, so drawWalks finds the hosts to fill.
export const WALK_HOST = "pg-walk";

function textBlock(block) {
  if (typeof block.html === "string") return html`<div class="pg-text markdown">${unsafeHTML(block.html)}</div>`;
  return html`<div class="pg-text pg-plain">${String(block.text ?? "")}</div>`;
}

// +table+: (block, index) => template (page_table.js), or null to show a
// table as an unknown block. +index+: the block's place on the page.
export function blockTemplate(block, { table = null } = {}, index = 0) {
  const type = block && typeof block === "object" ? block.type : null;
  if (type === "text") return textBlock(block);
  if (type === "walk") return html`<div class="${HOST} ${WALK_HOST}" .pageWalk=${block.data}></div>`;
  if (type === "table" && table) return table(block, index);
  return html`<div class="pg-unknown">A ${String(type || "block")} block this chi web doesn't draw.</div>`;
}

export function blocksTemplate(blocks, opts = {}) {
  if (!Array.isArray(blocks) || !blocks.length) return nothing;
  return blocks.map((block, index) => blockTemplate(block, opts, index));
}

// Fills each walk host under +root+ whose data changed since its last draw
// (a redraw of the same page keeps the walk where the reader left it).
export async function drawWalks(root, { doc = document, win = window, sheet = () => loadWidgetSheet(win) } = {}) {
  const hosts = [...root.querySelectorAll(`.${WALK_HOST}`)].filter((host) => host.pageWalk && host.drawnWalk !== host.pageWalk);
  if (!hosts.length) return;
  const css = await sheet();
  for (const host of hosts) {
    const data = host.pageWalk;
    if (host.drawnWalk === data) continue;
    host.drawnWalk = data;
    const shadow = host.shadowRoot || host.attachShadow({ mode: "open" });
    if (css) shadow.adoptedStyleSheets = [css];
    try {
      shadow.replaceChildren(drawWalk(data, doc));
    } catch (e) {
      const line = doc.createElement("div");
      line.className = "pg-unknown";
      line.textContent = `This walk can't be drawn: ${e?.message || e}`;
      shadow.replaceChildren(line);
    }
  }
}
