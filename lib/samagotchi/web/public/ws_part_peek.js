// The working set popover's prompt peek: a "From the start" row's ▸ opens,
// under the row, the text chi was sent for that prompt part (chi web's GET
// …/working_set/part, a slice of the session's saved head: WorkingSetPart).
// A memory's text and an .md file's render through the reader's markdown
// cache (+md+: ws_markdown.js), anything else as its source; the line chi
// adds before it folds under "chi adds a line before it". Tools open as
// their declared names and sizes. A prompt peek has no foot buttons: a
// memory never read has no timeline, and the row's name is not a link.
//
// One row, several holds (a note also preloaded, a prompt memory also
// read): one tab per hold, its kind and size ("note · ~0.9k"), and "read ·
// t1·s1" for the item's read, which is the item peek's (ws_peek.js, +itemPeek+)
// and opens first when there is one. When the sent text isn't there, one
// line says why (the route's words, case C of the plan), the source now
// under it when chi could fetch it.
//
// Made by ws_reader.js createWorkingSetPreview and handed to the view as
// its peek's +part+ (no new export on ws_reader.js): a view without it
// (an older cached ws_reader.js) draws today's rows. One peek open at a
// time across both kinds: opening here closes the item peek.

import { html, nothing } from "./vendor/lit-html.js";
import { api } from "./data.js";
import { createLatest } from "./latest.js";
import { textTemplate } from "./ws_cards.js";
import { peekMarkdownTemplate, peekText } from "./ws_markdown.js";
import { tokensText } from "./working_set.js";

// The part route's path for session +id+ and part +key+ (PromptPart.keys).
export function partPath(id, key) {
  return `/api/sessions/${encodeURIComponent(id)}/working_set/part?key=${encodeURIComponent(key)}`;
}

// The part route's answer.
export function getWorkingSetPart(id, key) {
  return api(partPath(id, key));
}

// A hold's tab word, by the part's kind.
const HOLD_WORDS = { notes: "note", preloads: "preload" };
const MEMORY_KINDS = ["identity", "notes", "preloads"];
const SENT = "in the prompt · sent with every request";

// A part key's kind ("notes:model_notes_y@system" → "notes").
const kindOf = (key) => String(key).split(":", 1)[0];

// Whether a part's text renders as markdown: a memory's, an .md file's.
function renders(part) {
  if (!part) return false;
  if (MEMORY_KINDS.includes(part.kind)) return true;
  return (part.kind === "agents" || part.kind === "appended") && /\.md$/i.test(String(part.ref || ""));
}

// +text+ rendered (+md+ has its HTML) or as its source.
function bodyTemplate(text, part, md) {
  const rendered = md && renders(part) ? peekMarkdownTemplate(text, md) : null;
  if (rendered) return rendered;
  return textTemplate(renders(part) ? peekText(text) : text, { fold: Infinity });
}

const leadTemplate = (lead) => (lead ? html`<details class="ws-lead"><summary>chi adds a line before it</summary><pre>${lead}</pre></details>` : nothing);

// The tools' names and sizes (a size only where the build had one per tool).
function toolsTemplate(tools) {
  return html`<div class="ws-tools">${tools.map((t) => html`<span class="ws-tool-n">${t.name}</span><span class="ws-tool-k">${Number.isFinite(t.chars) ? tokensText(Math.ceil(t.chars / 4)) : ""}</span>`)}</div>`;
}

// +session()+: the open session's id; +getPart(id, key)+: the part route;
// +itemPeek+: the rows' item peek (ws_peek.js; its template is the "read"
// tab); +md+: the reader's markdown cache; +onChange()+: the peek's content
// changed (the popover redraws and places itself again).
export function createPartPeek({ session, getPart = getWorkingSetPart, itemPeek = null, md = null, onChange = () => {} }) {
  let openId = null;
  let itemId = null;
  let row = null;
  let tab = null;
  // Answers by part key, for the open row; whether one failed.
  let answers = new Map();
  let failed = new Set();
  const latest = createLatest(() => `${session()}|${openId}|${tab}`);

  const holdsOf = (r, read) => [...(read ? ["read"] : []), ...(r?.partKeys || [])];

  function load(key) {
    const id = session();
    if (!id || !key || key === "read" || answers.has(key)) return;
    const fresh = latest.begin();
    Promise.resolve()
      .then(() => getPart(id, key))
      .then((answer) => {
        if (!fresh()) return;
        answers.set(key, answer);
        failed.delete(key);
        onChange();
      })
      .catch(() => {
        if (!fresh()) return;
        failed.add(key);
        onChange();
      });
  }

  // Shows +key+ (a part key, or "read": the item peek's).
  function show(key) {
    tab = key;
    if (key === "read") {
      if (itemPeek && !itemPeek.isOpen(itemId)) itemPeek.toggle(itemId, row);
    } else {
      if (itemPeek?.any()) itemPeek.close();
      load(key);
    }
  }

  function close() {
    if (openId && tab === "read") itemPeek?.close();
    openId = null;
    itemId = null;
    row = null;
    tab = null;
    answers = new Map();
    failed = new Set();
    latest.drop();
  }

  function partBody(key) {
    if (failed.has(key)) return html`<div class="ws-peek-note">Couldn't load the prompt part.</div>`;
    const data = answers.get(key);
    if (!data) return html`<div class="ws-peek-note">Loading…</div>`;
    if (Array.isArray(data.tools)) return html`<div class="ws-peek-b">${toolsTemplate(data.tools)}</div>`;
    if (data.sent) return html`<div class="ws-peek-b">${bodyTemplate(data.sent.text, data.part, md)}</div>${leadTemplate(data.sent.lead)}`;
    const now = data.now?.gone ? html`<div class="ws-peek-note">Its source is gone now.</div>`
      : data.now ? html`<div class="ws-peek-b">${bodyTemplate(data.now.text, data.part, md)}</div>` : nothing;
    return html`<div class="ws-peek-note">${data.note || ""}</div>${now}`;
  }

  const peek = {
    // +id+'s row opened, or closed when it was. +read+: the row's item has
    // a read to peek at (the item peek's tab, first), +item+ its id there
    // (working_set.js steerId: the timeline's way in).
    toggle(id, r, { read = false, item = null } = {}) {
      if (openId === id) close();
      else if (!holdsOf(r, read).length) return;
      else {
        if (openId) close();
        if (itemPeek?.any()) itemPeek.close();
        openId = id;
        itemId = item;
        row = r;
        show(holdsOf(r, read)[0] || null);
      }
      onChange();
    },
    isOpen: (id) => openId === id,
    any: () => openId !== null,
    close,
    // A tab of the open row chosen.
    tab(key) {
      if (!openId || key === tab) return;
      show(key);
      onChange();
    },
    // The peek under +r+ (the open row); +read+: its item has a read, +readTag+
    // its step tag ("t1·s1").
    template(r, { read = false, readTag = "" } = {}) {
      const holds = holdsOf(r, read);
      const current = holds.includes(tab) ? tab : holds[0];
      const tabs = holds.length > 1 ? html`<div class="ws-tabs" role="tablist">${holds.map((key, i) => {
        const words = key === "read" ? `read${readTag ? ` · ${readTag}` : ""}` : `${HOLD_WORDS[kindOf(key)] || "in the prompt"} · ${tokensText(r.partSizes?.[i - (read ? 1 : 0)])}`;
        return html`<button type="button" class=${`ws-tab${key === current ? " on" : ""}`} role="tab" aria-selected=${String(key === current)} @click=${() => peek.tab(key)}>${words}</button>`;
      })}</div>` : nothing;
      if (current === "read") return html`<div class="ws-peek ws-held" role="region" aria-label="What chi has">${tabs}${itemPeek ? itemPeek.template(r) : nothing}</div>`;
      const data = answers.get(current);
      const declared = Array.isArray(data?.tools) ? ` · ${data.tools.length} declared` : "";
      const head = holds.length < 2 && (data?.sent || data?.tools) ? html`<div class="ws-peek-h"><span class="ws-peek-t">${SENT}${declared}</span></div>` : nothing;
      return html`<div class="ws-peek ws-part-peek" role="region" aria-label="What chi was sent">${tabs}${head}${partBody(current)}</div>`;
    },
  };
  return peek;
}
