// Markdown in the working set's reader and peek (ws_cards.js, ws_reader.js,
// ws_peek.js): which texts render, the text to send, a leading front
// matter taken off, the HTML of each text kept for the page, and its
// template (lit: its spec loads dom_shim.js). The HTML comes from markdown_place.js
// renderMarkdown (POST /api/render, sanitised there); null is markdown off,
// a viewer that may not render, or a failed read: the source stays.
//
// What renders (docs/internals/web-frontend.md, The working set's reader):
// a memory's text (read, written, its overlay, the greyed "what it was") and
// a whole read of an .md file. A slice stays numbered source (it can start
// inside a fence or a list, and its line numbers are the strip's jumps); an
// edit or a write stays its diff; a fetch's text is not rendered.

import { html, nothing } from "./vendor/lit-html.js";
import { unsafeHTML } from "./vendor/directives/unsafe-html.js";

// The route's cap on its JSON body (web/message_display.rb MAX_RENDER_BYTES;
// block_host.js MAX_SOURCE_BYTES mirrors it too).
export const RENDER_MAX_BYTES = 64 * 1024;
// About how many texts the page keeps the HTML of.
const CACHE_MAX = 50;

const MD_FILE = /\.(md|markdown)$/i;
const MEMORY_CARDS = new Set(["memory", "written"]);
const MEMORY_OPS = new Set(["memory_read", "memory_write"]);

const markdownFile = (item) => item?.kind === "file" && MD_FILE.test(String(item.key || ""));

// A card (ws_timeline.js timelineCards) of +item+ that renders: a memory's,
// or a slice of an .md file that is the whole file (from line 1, one of its
// reads a whole one).
export function renderable(card, item) {
  if (!card) return false;
  if (MEMORY_CARDS.has(card.type)) return true;
  if (card.type !== "slice" || card.first !== 1 || !markdownFile(item)) return false;
  return (card.reads || []).some((read) => read?.lines?.whole);
}

// The same rule for the peek's event (ws_timeline.js peekOf): a memory read
// or write; a whole read of an .md file, not a preview of it.
export function renderableEvent(event, item) {
  if (!event) return false;
  if (MEMORY_OPS.has(event.op)) return true;
  return event.op === "read" && !!event.lines?.whole && !event.lines?.partial && markdownFile(item);
}

// The text a card renders: a slice's lines, else its event's text.
export function sourceText(card) {
  if (card?.type === "slice") return (card.rows || []).map((r) => r.text).join("\n");
  return String(card?.event?.text ?? "");
}

const FRONT = /^---[ \t]*\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/;

// A leading YAML front matter block (a --- line closed by a --- line):
// {front, body}, +front+ without its last newline; "" when there is none.
export function splitFrontMatter(text) {
  const all = String(text ?? "");
  const found = all.match(FRONT);
  if (!found) return { front: "", body: all };
  return { front: found[0].replace(/\r?\n$/, ""), body: all.slice(found[0].length) };
}

// The peek's source and rendered body omit a leading front matter block.
// The reader uses splitFrontMatter separately so it keeps that block above
// the rendered body.
export function peekText(text) {
  return splitFrontMatter(text).body;
}

const tooBig = (text) => new TextEncoder().encode(JSON.stringify({ text })).length > RENDER_MAX_BYTES;

// The page's HTML of each text: +html(text)+ answers the HTML, null (too big
// for the route: no request) or undefined while its one request is on its
// way (+onReady()+ runs when HTML comes). A null answer (markdown off, a
// failed read) is not kept, so the next draw asks again; at most one
// request per text at a time. Bounded (+max+), the least recently used
// text going first.
export function createRenderCache(renderMarkdown, onReady = () => {}, { max = CACHE_MAX } = {}) {
  const kept = new Map();
  const asking = new Set();

  function html(text) {
    const key = String(text ?? "");
    if (kept.has(key)) {
      const found = kept.get(key);
      kept.delete(key);
      kept.set(key, found);
      return found;
    }
    if (tooBig(key)) return null;
    if (asking.has(key)) return undefined;
    asking.add(key);
    let asked;
    try {
      asked = Promise.resolve(renderMarkdown(key));
    } catch {
      asked = Promise.resolve(null);
    }
    asked
      .catch(() => null)
      .then((answer) => {
        asking.delete(key);
        if (typeof answer !== "string" || !answer) return;
        kept.set(key, answer);
        while (kept.size > max) kept.delete(kept.keys().next().value);
        onReady();
      });
    return undefined;
  }

  return { html };
}

// +text+ as markdown: its front matter as source, then the HTML (sanitised
// on the server, POST /api/render); null while its HTML isn't there
// (+md.html+: undefined on its way, null off or failed).
export function markdownTemplate(text, md) {
  if (!md?.html) return null;
  const { front, body } = splitFrontMatter(text);
  const found = md.html(body);
  if (typeof found !== "string") return null;
  return html`${front ? html`<pre class="wsr-front">${front}</pre>` : nothing}<div class="wsr-md">${unsafeHTML(found)}</div>`;
}

// The peek renders only the front matter's body, without source above it.
export function peekMarkdownTemplate(text, md) {
  if (!md?.html) return null;
  const body = peekText(text);
  const found = md.html(body);
  if (typeof found !== "string") return null;
  return html`<div class="wsr-md">${unsafeHTML(found)}</div>`;
}
