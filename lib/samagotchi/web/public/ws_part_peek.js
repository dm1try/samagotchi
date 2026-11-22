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
// A stale hold (the row's partStates, from chi web's GET: its source
// changed since chi was sent it) gets a "now · changed" tab right after
// its own: the part route's &now=1, its diff from the sent text drawn as
// the reader draws a diff (diff_view.js). It opens first when the row has
// no read. Under it, when chi gets the new text (the route's rebuild: a
// live worker at its prompt's next build, else at its next turn), and,
// when chi changed it and it changed again after (the row's partByChi,
// current false), a line naming chi's edit.
//
// A hold chi changed itself ("edited" in partStates: the view lays the
// GET's by_chi on the row) gets an "edited · t3·s2" tab ("removed · …")
// in its place: the same &now=1 answer, headed "chi edited <label> at
// t3·s2", its diff, and the line that says both facts (the prompt still
// sends the old text; chi has the new text from its edit). An older
// cached peek sees no stale there and shows the sent text.
//
// Made by ws_reader.js createWorkingSetPreview and handed to the view as
// its peek's +part+ (no new export on ws_reader.js): a view without it
// (an older cached ws_reader.js) draws today's rows. One peek open at a
// time across both kinds: opening here closes the item peek.

import { html, nothing } from "./vendor/lit-html.js";
import { api } from "./data.js";
import { diffCounts, diffTemplate } from "./diff_view.js";
import { createLatest } from "./latest.js";
import { textTemplate } from "./ws_cards.js";
import { peekMarkdownTemplate, peekText } from "./ws_markdown.js";
import { tokensText } from "./working_set.js";

// The part route's path for session +id+ and part +key+ (PromptPart.keys);
// +now+: with the source now and its diff.
export function partPath(id, key, { now = false } = {}) {
  return `/api/sessions/${encodeURIComponent(id)}/working_set/part?key=${encodeURIComponent(key)}${now ? "&now=1" : ""}`;
}

// The part route's answer.
export function getWorkingSetPart(id, key, opts = {}) {
  return api(partPath(id, key, opts));
}

// A hold's tab word, by the part's kind.
const HOLD_WORDS = { notes: "note", preloads: "preload" };
const MEMORY_KINDS = ["identity", "notes", "preloads"];
const SENT = "in the prompt · sent with every request";
// A now tab's words when its row's read is stale too: both causes (the row says one "stale").
const BOTH_CHANGED = "read changed · prompt text changed";
// When chi's prompt gets the source now (the part route's rebuild).
const REBUILD_LIVE = "when its prompt is next built (a restart, a model switch)";
const REBUILD_NEXT = "at its next turn";
const STILL_SENT = "Its prompt still sends the old text with every request; chi has the new text from its edit.";
const PROMPT_GETS = { restart: "The prompt gets it when it is next built (a restart, a model switch).", next_turn: "The prompt gets it when it is next built (at its next turn)." };

// Whether the row's read is stale too (its item stale and read; one chi only wrote is stale by that write).
const readStale = (r) => r?.state === "stale" && (r.ops || []).includes("read");
// A part key's kind ("notes:model_notes_y@system" → "notes").
const kindOf = (key) => String(key).split(":", 1)[0];
// A stale hold's now tab: "now:" and its part's key.
const NOW = "now:";
const nowOf = (key) => (String(key).startsWith(NOW) ? String(key).slice(NOW.length) : null);
// A hold chi changed itself: "edited:" and its part's key.
const EDITED = "edited:";
const editedOf = (key) => (String(key).startsWith(EDITED) ? String(key).slice(EDITED.length) : null);
// The &now=1 tabs' part key (a now tab's, an edited tab's), else null.
const sourceOf = (key) => nowOf(key) ?? editedOf(key);

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

  // The row's tabs: its read, then each part's, a stale one's now after it.
  const holdsOf = (r, read) => [
    ...(read ? ["read"] : []),
    ...(r?.partKeys || []).flatMap((key, i) => {
      const st = r.partStates?.[i];
      return st === "stale" ? [key, `${NOW}${key}`] : st === "edited" ? [key, `${EDITED}${key}`] : [key];
    }),
  ];
  // The tab a row opens on: its read, else a changed part's now or edited tab, else its first.
  const firstOf = (holds) => (holds.includes("read") ? "read" : holds.find((key) => sourceOf(key)) || holds[0] || null);
  // A part's own change on the open row (+r+'s partByChi, its tag), by part key.
  const ownOf = (r, key) => {
    const i = (r?.partKeys || []).indexOf(key);
    return i < 0 ? { change: null, tag: "" } : { change: r.partByChi?.[i] || null, tag: r.partTags?.[i] || "" };
  };

  function load(key) {
    const id = session();
    if (!id || !key || key === "read" || answers.has(key)) return;
    const fresh = latest.begin();
    const now = sourceOf(key);
    Promise.resolve()
      .then(() => (now ? getPart(id, now, { now: true }) : getPart(id, key)))
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

  // A now tab's body (+key+: its part's): what changed since chi was sent
  // it, as a diff, and when chi gets it; chi's edit when it changed again
  // after chi's own change. A head changed since (case C 4-5): build 1's
  // line and the source under it.
  function nowBody(data, r, key) {
    const now = data.now;
    if (!data.sent) return null;
    // The route fetched nothing (the guard refused, the part no longer fetchable): never the sent text under "now".
    if (!now) return html`<div class="ws-peek-note">Couldn't fetch its source now.</div>`;
    const { change, tag } = ownOf(r, key);
    const again = change && change.current === false && tag ? html`<div class="ws-peek-copy warn">chi edited it at ${tag}; it changed again after that.</div>` : nothing;
    const when = data.rebuild ? html`<div class="ws-peek-copy">chi gets the new text ${data.rebuild === "restart" ? REBUILD_LIVE : REBUILD_NEXT}.</div>` : nothing;
    if (now.gone) return html`<div class="ws-peek-note">Its source is gone now.</div>${again}${when}`;
    const counts = now.diff?.text ? html`<div class="ws-peek-h"><span class="ws-peek-t">${readStale(r) ? `${data.part?.label || "It"}: ${BOTH_CHANGED}` : `${data.part?.label || "It"} changed after chi's prompt was built`}</span><span class="ws-peek-c">${diffCounts(now.diff)}</span></div>` : nothing;
    return html`${counts}<div class="ws-peek-b">${diffTemplate(now.diff)}</div>${again}${when}`;
  }

  // An edited tab's body: chi's own change (the &now=1 answer: sent → now),
  // and the line that says both facts; a remove, its one line.
  function editedBody(data, r, key) {
    if (!data.sent) return null;
    const { change, tag } = ownOf(r, key);
    const at = tag ? ` at ${tag}` : "";
    // The words follow chi's call, as the row's do: a remove says removed; an edit or a write says edited (an
    // AGENTS.md chi's write emptied reads gone, and is still chi's edit).
    if (change?.op === "remove") {
      return html`<div class="ws-peek-copy">chi removed it${at}; its prompt still sends it until it is next built.</div>`;
    }
    const now = data.now;
    if (!now) return html`<div class="ws-peek-note">Couldn't fetch its source now.</div>`;
    const head = html`<div class="ws-peek-h"><span class="ws-peek-t">chi edited ${data.part?.label || "it"}${at}</span>${now.diff?.text ? html`<span class="ws-peek-c">${diffCounts(now.diff)}</span>` : nothing}</div>`;
    const gets = PROMPT_GETS[data.rebuild] ? ` ${PROMPT_GETS[data.rebuild]}` : "";
    const body = now.gone ? html`<div class="ws-peek-note">Its source is gone now.</div>` : html`<div class="ws-peek-b">${diffTemplate(now.diff)}</div>`;
    return html`${head}${body}<div class="ws-peek-copy">${STILL_SENT}${gets}</div>`;
  }

  function partBody(key, r) {
    if (failed.has(key)) return html`<div class="ws-peek-note">Couldn't load the prompt part.</div>`;
    const data = answers.get(key);
    if (!data) return html`<div class="ws-peek-note">Loading…</div>`;
    const changed = nowOf(key) ? nowBody(data, r, nowOf(key)) : editedOf(key) ? editedBody(data, r, editedOf(key)) : null;
    if (changed) return changed;
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
        show(firstOf(holdsOf(r, read)));
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
      // A tab gone (its row's states changed): the one shown instead is asked for, never left loading.
      if (current !== tab && current !== "read") {
        tab = current;
        load(current);
      }
      const tabs = holds.length > 1 ? html`<div class="ws-tabs" role="tablist">${holds.map((key) => {
        const own = editedOf(key) ? ownOf(r, editedOf(key)) : null;
        const words = key === "read" ? `read${readTag ? ` · ${readTag}` : ""}` : nowOf(key) ? "now · changed"
          : own ? `${own.change?.op === "remove" ? "removed" : "edited"}${own.tag ? ` · ${own.tag}` : ""}`
            : `${HOLD_WORDS[kindOf(key)] || "in the prompt"} · ${tokensText(r.partSizes?.[r.partKeys.indexOf(key)])}`;
        const title = nowOf(key) ? (readStale(r) ? BOTH_CHANGED : "its source changed after chi's prompt was built")
          : own ? "chi changed it itself: the new text is in its conversation" : nothing;
        return html`<button type="button" class=${`ws-tab${key === current ? " on" : ""}${nowOf(key) ? " warn" : ""}`} title=${title} role="tab" aria-selected=${String(key === current)} @click=${() => peek.tab(key)}>${words}</button>`;
      })}</div>` : nothing;
      if (current === "read") return html`<div class="ws-peek ws-held" role="region" aria-label="What chi has">${tabs}${itemPeek ? itemPeek.template(r) : nothing}</div>`;
      const data = answers.get(current);
      const declared = Array.isArray(data?.tools) ? ` · ${data.tools.length} declared` : "";
      const head = holds.length < 2 && (data?.sent || data?.tools) ? html`<div class="ws-peek-h"><span class="ws-peek-t">${SENT}${declared}</span></div>` : nothing;
      return html`<div class="ws-peek ws-part-peek" role="region" aria-label="What chi was sent">${tabs}${head}${partBody(current, r)}</div>`;
    },
  };
  return peek;
}
