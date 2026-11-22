// The working set's page parts (web.working_set, the stage view): the turns'
// sets the page keeps (a reload's, then one per hand-off), the footprint
// line under each finished turn's block, the session bar's "set N" chip,
// the expanded view (a chip_popover.js popover; a bottom sheet on a phone)
// and the step tags' jump to a call. The rail is working_set_rail.js's; the
// rules are working_set.js's.
//
// Steering (drop / undrop, pin / unpin, + add): the list's rows and groups post
// `/working-set drop|undrop|pin|unpin|add KEY…` lines (+sendLine+, the session
// command route). The list's foot (the sheet's last row) adds what the user
// types (a path, memory:NAME or a URL); a stale or forgotten row offers
// refresh (an add of it). An add is pending until the next turn sends its
// note: the server's snapshot lists it (adds) between turns, a queued line
// mid-turn; an added item the set doesn't hold yet is a `+ name` row with
// `reads next turn` and an undo (unadd). Between turns one runs at once: its command_ran re-reads the
// conversation and the re-emitted set strikes the item `dropped` (or marks
// it pinned). A row offers pin only when the session's strategy has the
// forget layer (forgetOn: pins guard against the model's forget); a pinned
// row shows its 📌 and unpin under any strategy, since its drop waits for
// the unpin. While a
// turn runs it is queued: its command_queued (waits: "turn_end"; any
// client's, and the snapshot's replay after a reload) makes it pending, a
// dashed-warn row with a pill and an undo (the inverse line, queued after
// it), until its command_ran. On a phone's sheet a tap on a row opens its
// action strip under it, one at a time.
//
// The server's projection (WorkingSet: a :working_set_updated event, a GET
// working_set when a session's set is seeded and when the expanded view
// opens) is one session-wide snapshot: an event always taken, a GET's
// answer unless an event overtook it (working_set.js newerSnapshot); every form
// overlays its state and tokens on the rows' items by key (working_set.js
// overlay), so a state is the item's now, not then. A new snapshot redraws
// them all: the chip, the open popover, the footprints in place and the rail
// (onServer).
//
// A row's place is ordinals, stamped on the DOM: data-turn on a turn's
// .turn-work block (its place in the page's turns) and data-at="step.row"
// on its tool rows, live (stampRows) and reloaded (stampHistory); a jump
// finds the row by them, never by a row key.
import { html, nothing, render, svg } from "./vendor/lit-html.js";
import { repeat } from "./vendor/directives/repeat.js";
import { createChipPopover, SHEET_SHARE, SHEET_TALL } from "./chip_popover.js";
import { stillOn } from "./latest.js";
import { showRow } from "./refs.js";
import { read as readPref, write as writePref } from "./session_prefs.js";
import {
  foldedSections, headItems, headLine, headSections, heldTwice, heldTwiceNote, lensTouched, memoryPartWords, promptKeys, startTokensText, WS_SECTION_FOLD,
} from "./ws_sections.js";
import {
  addedItems, addLine, bodySections, BUDGETS, dropRefusal, footprint, footprintText, forgetOn, GLYPHS, INVERSE, isFresh, itemKey, itemsOfTurn, labelText,
  labelTitle, lensItem, newerSnapshot, opsText, overlay, parseSteerLine, pendingSteers, pinnable, refreshable, serverAddIds, sessionItems, STEER_OPS,
  steerId, steerLine, stepRange, stepTag, tokensText, turnLens, undroppable,
} from "./working_set.js";
import { serverSig } from "./ws_item_sig.js";
import { placeOf } from "./ws_timeline.js";
import { heldOrder, recencyOrder } from "./ws_order.js";

// The popover's width, open row or not (a peek no longer widens it: the rows
// stayed put only at one width).
const WIDTH = 520;
// A stale start row's title words (ws_part_peek.js's now tab says the same).
const PART_CHANGED = "changed after chi's prompt was built";
const BOTH_CHANGED = "read changed · prompt text changed";
// A prompt row whose source chi changed itself (the GET's by_chi, current):
// its title after "chi edited it at …".
const OWN_EDITED = "the new text is in its conversation; its prompt still sends the old text until it is next built";
const OWN_REMOVED = "its prompt still sends it until it is next built";

// The popover's files fold to this many lines (groups open in place, one at
// a time), its memories past this many to one group.
const POP_BUDGET = 6;

// A row a peek opens on: one the session's runs touched (not an add, a
// muted or a preloaded-only memory).
function peekable(item) {
  return !item.added && !item.muted && item.ops.length > 0;
}

// A reloaded turn's items: its steps (timing.js turnGroups) as gens.
export function groupItems(group, ordinal) {
  return itemsOfTurn({ gens: (group.steps || []).map((step) => ({ tools: step.tools || [] })) }, ordinal);
}

// The live turn's block and rows stamped with their ordinals (+turn+: the
// turn's model; new rows only).
export function stampRows(blockEl, turn, ordinal) {
  if (!blockEl || !turn) return;
  if (blockEl.dataset.turn !== String(ordinal)) blockEl.dataset.turn = String(ordinal);
  turn.gens.forEach((gen, step) => {
    gen.tools.forEach((row, i) => {
      const el = blockEl.querySelector(`.activity-row[data-key="${String(row.key).replace(/"/g, '\\"')}"]`);
      if (el && !el.dataset.at) el.dataset.at = `${step}.${i}`;
    });
  });
}

// A reloaded history's blocks stamped: +blocks+ the .turn-work elements,
// +ordinals+ each one's turn.
export function stampHistory(blocks, ordinals) {
  blocks.forEach((block, i) => {
    block.dataset.turn = String(ordinals[i]);
    [...block.querySelectorAll(":scope > .gen")].forEach((gen, step) => {
      [...gen.querySelectorAll(":scope > .activity-body > .activity-row")].forEach((row, j) => { row.dataset.at = `${step}.${j}`; });
    });
  });
}

function atAttr(at) {
  return `${at.turn}.${at.step}.${at.row}`;
}

// A label's step tag in the footprint: a memory's step, a memory group's
// range (it jumps to the first); none for files and URLs.
function footTag(label) {
  if (label.kind !== "memory") return nothing;
  const first = label.members.find((m) => m.at);
  if (!first) return nothing;
  const text = label.type === "leaf" ? stepTag(first) : stepRange(label.members);
  const title = label.type === "leaf" ? `entered at step ${first.at.step + 1}: go to the call` : `entered at ${text}: go to the first call`;
  return html` <button type="button" class="ws-step p" data-ws="jump" data-at=${atAttr(first.at)} title=${title}>${text}</button>`;
}

// The footprint of a finished turn's +items+ (turn +ordinal+), nothing for a
// turn that touched nothing: "touched web/public/ · 9 files · ◆ 3 memories
// s1–5 · +1 url · edited 2". It sits in the turn block's summary line, so a
// span (phrasing content). A click opens the expanded view at that turn; a
// step tag jumps to its call.
export function footprintTemplate(items, ordinal) {
  const fp = footprint(items, BUDGETS.footprint);
  if (!fp) return nothing;
  const sep = html` <span class="sep">·</span> `;
  const parts = fp.labels.map((l, i) => html`${i ? sep : nothing}<span class=${`l ${l.kind}${l.state && l.state !== "live" ? ` ${l.state}` : ""}`} title=${labelTitle(l)}>${l.glyph ? html`<span class="k">${l.glyph}</span> ` : nothing}${labelText({ ...l, glyph: "" })}</span>${footTag(l)}`);
  const text = footprintText(items, BUDGETS.footprint);
  return html`<span class="ws-foot" role="button" tabindex="0" aria-haspopup="dialog" aria-expanded="false" data-ws-turn=${ordinal} data-ws-sig=${footSig(items)} aria-label=${`Working set of this turn: ${text.replace(/^touched /, "")}. Open the list.`}><span class="w">touched</span> ${parts}${fp.tail ? html`${sep}<span class="w">${fp.tail}</span>` : nothing}${fp.edited ? html`${sep}<span class="e">edited ${fp.edited}</span>` : nothing}${fp.stale ? html`${sep}<span class="s">${fp.stale} stale</span>` : nothing}${fp.forgotten ? html`${sep}<span class="f">${fp.forgotten} forgotten</span>` : nothing}${fp.dropped ? html`${sep}<span class="f">${fp.dropped} dropped</span>` : nothing}</span>`;
}

// What a footprint shows that can change after it is drawn: its items'
// states (the server's). The same signature draws nothing.
function footSig(items) {
  return items.map((i) => `${i.kind}:${i.key}:${i.state || "live"}`).join("|");
}

// The footprint as an element (the hand-off's), or null.
export function footprintNode(items, ordinal) {
  const template = footprintTemplate(items, ordinal);
  if (template === nothing) return null;
  const frag = document.createDocumentFragment();
  render(template, frag);
  return frag.querySelector(".ws-foot");
}

function ringTemplate(pct) {
  if (!Number.isFinite(pct)) return nothing;
  const value = Math.max(0, Math.min(100, Math.round(pct)));
  const len = 2 * Math.PI * 5.5;
  const bucket = value >= 90 ? " danger" : value >= 70 ? " warn" : "";
  return html`<svg class=${`ws-ring${bucket}`} viewBox="0 0 14 14" role="img">${svg`<title>context ${value}% used</title><circle class="track" cx="7" cy="7" r="5.5"></circle><circle class="fill" cx="7" cy="7" r="5.5" stroke-dasharray=${`${(len * value) / 100} ${len}`}></circle>`}</svg>`;
}

// A group's member as the popover names it: its path below the group's
// directory ("adapters/by_api.rb"), else its leaf text.
function memberName(item, group) {
  if (item.kind === "file" && group?.dir) return String(item.path || item.key).slice(group.dir.length + 1);
  return item.label;
}

// +historyEl+: where finished turns are; +stageRoot()+: the stage (the live
// turn's block); +state()+: the open session's fields (session_state.js:
// ctxPct, ctxTokens, ctxWindow, the prompt's parts and the preloaded,
// prompt-note, muted and used memories); +session()+: its id;
// +infoEl+: the session bar's line (the chip's popover is delegated there);
// +onChange()+: the chip's count or dot changed (app.js updateInfoBar).
// +getWorkingSet(id)+: the server's projection (data.js; null: none asked).
// +sendLine(line)+: posts a steer line as the session's command (null: no
// steering, the list reads only).
// +peek+: the rows' peek (ws_peek.js createPeek; null: none, a participant's
// list); +onTimeline(item)+: opens the item's reader (ws_reader.js; null:
// none).
export function createWorkingSet({ historyEl, stageRoot = () => null, state, session = () => null, infoEl, onChange = () => {}, getWorkingSet = null,
  sendLine = null, peek = null, onTimeline = null, doc = document }) {
  // The finished turns' sets ({items, prompt}), the running turn's (null:
  // none), the rail's first-sight times (its fresh cue), the session count
  // at the last open (the chip's dot).
  let turns = [];
  let live = null;
  let seenAt = () => undefined;
  let openedCount = 0;
  // The open view: its lens (null: the session; a turn's index: that turn
  // lit on the session's list), the group open in it.
  let lens = null;
  let openGroup = null;
  // The list's order taken at the open (ws_order.js): the item keys, last
  // touched first. Held while it is open (rows that come go on top, the
  // others stay); every open takes it again (null: closed).
  let openKeys = null;
  // What the drawn list shows of the context's tokens (tokenText): a chunk's
  // new count redraws it only when that text changes.
  let shownTokens = null;
  // The server's snapshot ({items, at}) and the session it is of; what
  // redraws the rail when it changes. +events+ counts the events taken, so
  // a GET knows whether one came while it was on its way.
  let server = null;
  let serverOf = null;
  let events = 0;
  // The steer lines queued for after the running turn, by command id, and
  // the session they are of; the row whose action strip is open (a sheet).
  const queued = new Map();
  let queuedOf = null;
  let stripOpen = null;
  const listeners = new Set();
  const lit = (items) => overlay(items, server);
  // The prompt parts whose source changed since chi was sent them (chi
  // web's GET's parts, WorkingSetPart.states): a GET's word, kept across
  // the events' sets (takeServer), asked again at each open, a rebuilt
  // prompt and a hand-off.
  const partStates = () => (Array.isArray(server?.parts) ? server.parts : null);
  // What the states say, to tell two answers' apart ("" for none).
  const partsSig = (parts) => (Array.isArray(parts) && parts.length ? JSON.stringify(parts) : "");
  // chi's own change of each stale part the GET named (by_chi: {tool_id,
  // step, op, current}), by part key. Read here, off the GET's parts, not
  // through ws_sections.js (an older cached one maps states to "stale").
  const partChanges = () => new Map((partStates() || []).filter((s) => s && typeof s.key === "string" && s.by_chi && typeof s.by_chi === "object").map((s) => [s.key, s.by_chi]));
  // Where a call sits in the page's turns ({turn, step, row}), by its chi id
  // (ws_timeline.js placeOf over every turn's items), or null.
  const placeFor = (toolId) => {
    for (const items of [...turns.map((t) => t.items), live?.items || []]) {
      for (const item of items || []) {
        const at = placeOf({ tool_id: toolId }, item);
        if (at) return at;
      }
    }
    return null;
  };
  // A change's step tag: its place in the turns ("t3·s2"), else the
  // server's step ("step 5"); +where+ the title's words.
  const changeTag = (change) => {
    const at = placeFor(change.tool_id);
    if (at) return { at, text: stepTag({ at }, { session: true }), where: `turn ${at.turn + 1}, step ${at.step + 1}` };
    const step = Number.isFinite(change.step) ? `step ${change.step}` : "";
    return { at: null, text: step, where: step || "a step" };
  };
  // A start row with chi's own changes laid on it: each stale part chi's
  // current change made "edited" (partStates; the peek's edited tab), the
  // row partEdited ({op, tag}) when no part of it is stale any more;
  // partByChi and partTags beside partKeys for the peek's lines (a stale
  // part chi changed, then it changed again). A row without partKeys (an
  // older cached ws_sections.js) as it is.
  const ownRow = (row) => {
    const keys = row?.partKeys;
    if (!Array.isArray(keys) || !Array.isArray(row.partStates)) return row;
    const changes = partChanges();
    const byChi = keys.map((key) => changes.get(key) || null);
    if (!byChi.some(Boolean)) return row;
    const tags = byChi.map((change) => (change ? changeTag(change) : null));
    const partStates = row.partStates.map((st, i) => (st === "stale" && byChi[i]?.current === true ? "edited" : st));
    const partStale = partStates.includes("stale");
    const edited = !partStale && partStates.includes("edited");
    const last = edited ? partStates.map((st, i) => (st === "edited" ? i : -1)).filter((i) => i >= 0).sort((a, b) => (byChi[a].step || 0) - (byChi[b].step || 0)).at(-1) : -1;
    return { ...row, partStates, partStale, partByChi: byChi, partTags: tags.map((t) => t?.text || ""), partEdited: edited ? { op: byChi[last].op, tag: tags[last] } : null };
  };
  // The session's prompt parts as built (each part's head and digest): a new
  // build asks the GET again, so a rebuilt prompt's stale states go.
  let builtSig = null;
  let builtOf = null;
  const builtSigOf = (parts) => JSON.stringify((Array.isArray(parts) ? parts : []).map((p) => [p?.kind, p?.head, p?.digest]));
  // The prompt peek of "From the start" rows (ws_part_peek.js), on the peek
  // a newer ws_reader.js makes; none (an older cached one): today's rows.
  const part = peek?.part || null;
  const anyPeek = () => !!(peek?.any() || part?.any());

  const sessionSet = () => {
    const st = state();
    const set = sessionItems({
      turns: turns.map((t) => t.items), live: live?.items || [], preloaded: st.preloadedMemories, notes: st.promptNotes, muted: st.mutedMemories,
      used: st.usedMemories,
    });
    return { items: lit(set.items), muted: set.muted };
  };
  // The turns the lens steps through: the finished ones and the running one.
  const lastTurn = () => turns.length + (live ? 1 : 0) - 1;
  const curLens = () => (lens !== null && lens > lastTurn() ? null : lens);
  const turnItems = (t) => lit(live && t === live.ordinal ? live.items : turns[t]?.items || []);
  const promptOf = (t) => (live && t === live.ordinal ? live.prompt : turns[t]?.prompt || "");

  const popover = createChipPopover({
    id: "workingSetPopover", className: "ctx-popover ws-popover", width: () => WIDTH, el: infoEl, anchor: ".ws-chip",
    openers: ".ws-chip, .ts-ws, .ws-foot", sheet: true, label: "Working set", sheetShare: () => (anyPeek() ? SHEET_TALL : SHEET_SHARE),
    // The chip opens the session lens; the rail and a footprint set theirs
    // before they open it.
    summary: (anchor) => {
      if (anchor?.matches?.(".ws-chip")) {
        lens = null;
        // Opened: the chip's dot goes (chip()).
        queueMicrotask(onChange);
      }
      return { lens };
    },
    session,
    // Opened: the server's set asked again (a file changed while the
    // session sat idle shows stale).
    // The order is taken again at each open (a footprint or the rail while
    // it is open too: they open it again).
    show: (_data, opening) => {
      if (opening) openKeys = recencyOrder(sessionSet().items).map(itemKey);
      draw();
      if (opening) fetchServer();
    },
    onClose: () => { openGroup = null; openKeys = null; part?.close(); peek?.close(); onChange(); },
    // The foot's + add (the popover's submit): one KEY as typed (quoted
    // when it has spaces).
    onSubmit: (form) => {
      if (!form?.matches?.(".ws-add")) return;
      const input = form.querySelector(".ws-add-in");
      const line = sendLine && addLine(input?.value);
      if (!line) return;
      input.value = "";
      Promise.resolve(sendLine(line)).catch(() => {});
    },
  });

  // The pending ops: the server's adds (made between turns), then the
  // queued lines.
  const pending = () => pendingSteers([...queued.values()], state().dir, serverAddIds(server));
  // The pending adds the set doesn't hold yet, as rows.
  const adding = (pend = pending()) => addedItems(pend, sessionSet().items, server, state().dir);

  // A steer button: +op+ on +items+ ("undo" sends the inverse of a pending op).
  function actButton(op, items, { label = op, title = "", disabled = false } = {}) {
    // JSON: an id may hold spaces (a file under "my notes/").
    const ids = JSON.stringify(items.map(steerId));
    return html`<button type="button" class=${`ws-act-b ${op}`} data-ws="steer" data-op=${op} data-ids=${ids} title=${title} ?disabled=${disabled}>${label}</button>`;
  }

  // A pending op's pill.
  const PILLS = { drop: "drops next turn", undrop: "back next turn", pin: "applies next turn", unpin: "applies next turn",
    add: "reads next turn" };

  // What a row offers: a pending op's pill and undo, an undrop, a drop (or
  // why not), a pin or an unpin; nothing for an item no op applies to.
  function rowActions(item, pend, forget) {
    if (!sendLine) return { pill: nothing, buttons: nothing };
    let op = pend.get(steerId(item));
    // A drop queued for a pinned item: the worker refuses it (unpin it
    // first), so it isn't pending; the row offers its greyed drop.
    if (op === "drop" && item.pinned) op = undefined;
    if (op) {
      const when = op === "add" ? "the next turn's note asks the model to read it first" : "applies at the next turn's start";
      const pill = html`<span class="ws-pend" title=${when}>${PILLS[op]}</span>`;
      return { pill, buttons: actButton(INVERSE[op], [item], { label: "undo", title: `take back the queued ${op}` }) };
    }
    const undrop = actButton("undrop", [item], { title: "send it whole again from the next request (a cache break)" });
    // Dropped, or a drop on some reads with nothing else of it sent (the
    // model's layers stubbed the rest): undrop is all it offers.
    if (item.state === "dropped" || (undroppable(item) && item.state === "forgotten")) return { pill: nothing, buttons: undrop };
    const buttons = [];
    const why = dropRefusal(item);
    if (why !== null) buttons.push(actButton("drop", [item], { title: why || "send a stub instead of its reads from the next turn's start", disabled: !!why }));
    if (item.pinned) buttons.push(actButton("unpin", [item], { title: "the model's forget_outputs may forget it again" }));
    else if (forget && pinnable(item)) buttons.push(actButton("pin", [item], { title: "keep it from the model's forget_outputs (its later reads too)" }));
    // A drop on some of its reads, others still sent: undrop takes it back.
    if (undroppable(item)) buttons.push(undrop);
    if (refreshable(item)) buttons.push(actButton("add", [item], { label: "refresh", title: "the next turn's note asks the model to read it again" }));
    return { pill: nothing, buttons: buttons.length ? buttons : nothing };
  }

  // +touched+ (a turn lens): the turn's items by key. A row it holds is lit
  // and draws the turn's `at` and ops (its step tag, its words) on the
  // session item's state, tokens and actions; the others dim.
  // +start+: a "From the start" memory row (ws_sections.js): its part's
  // words and tokens, no "prompt" tag (the section says it), "held twice"
  // when it was read again, and the note in a turn lens that read it.
  function rowTemplate(given, { session: inSession, group = null, now, pend = new Map(), forget = false, touched = null, start = false }) {
    // A start row with chi's own changes of its parts laid on it (ownRow).
    const row0 = start ? ownRow(given) : given;
    // +row0+ is the session's item: its state, tokens, actions, peek. +item+ is
    // what the lens shows of it: the turn's `at`, ops and count (the step tag,
    // the words, the edited mark) and nothing else.
    const item = touched ? lensItem(row0, touched) : row0;
    const lensClass = touched && !row0.added ? (touched.has(itemKey(row0)) ? " lit" : " dim") : "";
    // A dimmed row's tag is the session's last touch ("t3·s4"; an older
    // page's item: its first entry); a lit row's the turn's entry ("s3").
    // By the lens class: a lit row carries the session's `last` too.
    const whole = inSession || lensClass === " dim";
    const place = whole ? row0.last || row0.at : item.at;
    const fresh = isFresh(seenAt(row0), now);
    // A lit preloaded memory the turn read shows the turn's step, not "prompt".
    const tag = stepTag(lensClass === " lit" && item.at ? { ...item, preloaded: false } : { ...item, at: place }, { session: whole });
    const note = start && touched ? heldTwiceNote(row0, touched.get(itemKey(row0))) : "";
    // An added row's words: what it is (a phone's tap on them opens its strip).
    const what = start ? [memoryPartWords(row0), row0.state && row0.state !== "live" ? row0.state : ""].filter(Boolean).join(" · ") : opsText(item);
    const words = item.added ? "added" : `${what}${fresh ? " · just now" : ""}`;
    const glyph = item.added ? "+" : item.muted ? GLYPHS.muted : fresh ? "●" : GLYPHS[item.kind] || "";
    const name = memberName(row0, group);
    const full = item.kind === "file" ? item.path || item.key : item.kind === "url" ? item.url || item.key : item.key;
    let nameEl;
    if (item.kind === "file") {
      const ref = item.ref || { path: full };
      nameEl = html`<span class="t ref" data-ref-kind="file" data-ref-path=${ref.path || full} data-ref-line=${ref.line || nothing} data-ref-end-line=${ref.end_line || nothing} title=${full}>${name}</span>`;
    } else if (item.kind === "url" && /^https?:\/\//i.test(full)) {
      nameEl = html`<a class="t" href=${full} target="_blank" rel="noopener noreferrer" title=${full}>${name}</a>`;
    } else {
      nameEl = html`<span class="t" title=${full}>${name}</span>`;
    }
    let tagEl = nothing;
    if (start && inSession && heldTwice(row0)) tagEl = html`<span class="ws-twice" title="already in the prompt and read again: held twice">held twice</span>`;
    else if (tag === "prompt") tagEl = start ? nothing : html`<span class="ws-step p" title="in the system prompt">prompt</span>`;
    else if (tag) {
      const prompt = whole ? promptOf(place.turn) : "";
      const where = whole ? `turn ${place.turn + 1}${prompt ? ` (${prompt})` : ""}, step ${place.step + 1}` : `step ${place.step + 1}`;
      tagEl = html`<button type="button" class=${`ws-step${item.kind === "memory" ? " p" : ""}${note ? " twice" : ""}`} data-ws="jump" data-at=${atAttr(place)} title=${`${whole ? "last touched" : "entered"} at ${where}: go to the call`}>${tag}</button>`;
    }
    const edited = item.kind === "file" && item.ops.includes("edit");
    const state = row0.state && row0.state !== "live" ? ` ${row0.state}` : "";
    const tokens = start ? startTokensText(row0) : tokensText(row0.tokens);
    const id = steerId(row0);
    const { pill, buttons } = rowActions(row0, pend, forget);
    const pin = row0.pinned ? html`<span class="ws-pin" title="pinned: the model's forget_outputs refuses it">📌</span>` : nothing;
    const isPending = pill !== nothing;
    const strip = stripOpen === id && buttons !== nothing;
    const open = item.kind === "file" ? html`<button type="button" class="ws-act-b open ref" data-ref-kind="file" data-ref-path=${item.ref?.path || full}>open</button>` : nothing;
    // The ▸ that peeks at what chi has of it (the owner's: +peek+); a start
    // row's opens the prompt peek, its read (when it has one) a tab of it;
    // a row without its parts' keys (an older cached ws_sections.js) keeps today's.
    const prompt = start && !!part && !!row0.partKeys?.length;
    const partId = prompt ? `start:${itemKey(row0)}` : null;
    const canPeek = prompt || (peek && peekable(row0));
    const peeked = prompt ? part.isOpen(partId) : canPeek && peek.isOpen(id);
    const toggle = prompt ? partToggle(partId, row0, name, peeked, { read: !!peek && peekable(row0), item: id })
      : canPeek ? html`<button type="button" class="ws-peek-toggle" data-ws="peek" data-ws-id=${id} aria-expanded=${String(peeked)} aria-label=${`What chi has of ${name}`} title="What chi has of it">${peeked ? "▾" : "▸"}</button>` : nothing;
    const peekEl = !peeked ? nothing : prompt ? part.template(row0, { read: !!peek && peekable(row0), readTag: stepTag({ ...row0, preloaded: false, at: row0.last || row0.at }, { session: true }) }) : peek.template(row0);
    // A prompt row whose source changed since chi was sent it says "stale" in place of its words, kept in
    // its title; a read stale too: still one word, both causes in the title.
    const pstale = start && !item.added && row0.partStale;
    // A prompt row whose source chi changed itself: ✎, its words then "edited" (the read's own stale wins), its
    // tag the call's.
    const pedited = start && !item.added && !!row0.partEdited && row0.state !== "stale";
    if (pedited) tagEl = html`${tagEl}${ownTagTemplate(row0.partEdited)}`;
    const staleTitle = pstale ? `${row0.state === "stale" ? `${memoryPartWords(row0)} · ${BOTH_CHANGED}` : `${what} · ${PART_CHANGED}`}${fresh ? " · just now" : ""}` : "";
    const row = html`<div class=${`ws-row ${item.kind}${row0.added ? " added" : ""}${fresh ? " fresh" : ""}${row0.muted ? " muted" : ""}${group ? " member" : ""}${state}${isPending ? " pending" : ""}${strip ? " strip-open" : ""}${peeked ? " peeked" : ""}${canPeek ? " peekable" : ""}${note ? " twice" : ""}${lensClass}`} data-ws-id=${id}>${toggle}<span class="k">${glyph}</span>${nameEl}${pin}${edited || pedited ? html`<span class="e">✎</span>` : nothing}${pstale ? staleTemplate(staleTitle) : pedited ? ownTemplate(memoryPartWords(row0), row0.partEdited) : html`<span class="st">${words}</span>`}${pill}${tokens ? html`<span class="tk" title=${start ? "about its tokens in the prompt, + its reads'" : `about ${row0.tokens} tokens of it are sent`}>${tokens}</span>` : nothing}${tagEl}${buttons !== nothing ? html`<span class="ws-act">${buttons}</span>` : nothing}</div>`;
    // One template either way, so the tapped row stays the same node (a
    // click outside the popover closes it).
    const noteEl = note ? html`<div class="ws-note twice" role="note">${note}</div>` : nothing;
    return html`${row}${noteEl}${strip ? html`<div class="ws-strip">${buttons}${open}</div>` : nothing}${peekEl}`;
  }

  // A prompt row's "stale": its source changed since chi was sent it.
  const staleTemplate = (title = `its source ${PART_CHANGED}`) => html`<span class="st ws-pstale" title=${title}>stale</span>`;

  // A prompt row chi changed itself: its part words (a phone's sheet hides them, .ws-pwords) then "edited"
  // ("removed"), the title saying both facts.
  function ownTemplate(words, own) {
    const removed = own.op === "remove";
    const title = `${words ? `${words} · ` : ""}chi ${removed ? "removed" : "edited"} it at ${own.tag.where}: ${removed ? OWN_REMOVED : OWN_EDITED}`;
    return html`<span class="st ws-pedited" title=${title}>${words ? html`<span class="ws-pwords">${words} · </span>` : nothing}${removed ? "removed" : "edited"}</span>`;
  }

  // Its tag: the call's place, a jump as the read rows' (a plain "step N" without one).
  function ownTagTemplate(own) {
    const { at, text, where } = own.tag;
    if (!text) return nothing;
    const title = `chi ${own.op === "remove" ? "removed" : "edited"} it at ${where}: go to the call`;
    return at ? html`<button type="button" class="ws-step p ws-own" data-ws="jump" data-at=${atAttr(at)} title=${title}>${text}</button>`
      : html`<span class="ws-step p ws-own" title=${title}>${text}</span>`;
  }

  // A start row's ▸: the prompt peek (+opts+: its read, its item's id).
  function partToggle(id, row, name, peeked, opts) {
    return html`<button type="button" class="ws-peek-toggle" data-ws-part-peek=${id} aria-expanded=${String(peeked)} aria-label=${`What chi was sent of ${name}`} title="What chi was sent" @click=${() => part.toggle(id, row, opts)}>${peeked ? "▾" : "▸"}</button>`;
  }

  // A prompt part's row: its label, its sub, its tokens; read-only. Its ▸
  // (with the prompt peek: a newer ws_reader.js) opens what chi was sent.
  // Never touched by a turn: dim in a turn lens.
  function partRowTemplate(given, { touched = null }) {
    const row = ownRow(given);
    const lensClass = touched ? " dim" : "";
    const tokens = tokensText(row.partTokens);
    const opens = !!part && !!row.partKeys?.length;
    const id = opens ? `start:part:${row.key}` : null;
    const peeked = opens && part.isOpen(id);
    const toggle = opens ? partToggle(id, row, row.label, peeked, {}) : nothing;
    return html`<div class=${`ws-row ${row.kind}${lensClass}${opens ? " peekable" : ""}${peeked ? " peeked" : ""}`} data-ws-part=${row.key}>${toggle}<span class="k"></span><span class="t" title=${row.sub ? `${row.label}: ${row.sub}` : row.label}>${row.label}</span>${row.partEdited ? html`<span class="e">✎</span>` : nothing}${row.partStale ? staleTemplate(row.sub ? `${row.sub} · ${PART_CHANGED}` : undefined) : row.partEdited ? ownTemplate(row.sub, row.partEdited) : row.sub ? html`<span class="st">${row.sub}</span>` : nothing}${tokens ? html`<span class="tk" title="about its tokens in every request">${tokens}</span>` : nothing}${row.partEdited ? ownTagTemplate(row.partEdited) : nothing}</div>${peeked ? part.template(row) : nothing}`;
  }

  // The Conversation section as one row at section level ("Conversation ·
  // N turns ~X"): nothing to fold, read-only, never touched by a turn (dim
  // in a turn lens).
  function talkTemplate(section, { touched = null }) {
    const row = section.rows[0];
    return html`<div class=${`ws-row talk ws-sec-row${touched ? " dim" : ""}`} data-ws-part=${row.key}><span class="k"></span><span class="t">${section.title}</span>${row.sub ? html`<span class="n">· ${row.sub}</span>` : nothing}<span class="tk" title="about the conversation's tokens: the context's less the prompt's parts and the held reads">${tokensText(section.tokens)}</span></div>`;
  }

  // A head section's row: a part or a memory part.
  const startRow = (row, opts) => (row.kind === "memory" ? rowTemplate(row, { ...opts, start: true }) : partRowTemplate(row, opts));
  const isLit = (item, opts) => !!opts.touched && opts.touched.has(itemKey(item));

  // The head view's sections (ws_sections.js headSections), read · talk ·
  // start: each header folds (per session, session_prefs.js WS_SECTION_FOLD;
  // none stored: start folded); folded, a section
  // shows only the rows the lens lights. Conversation is one row, no header,
  // no fold (a stored fold naming it is ignored).
  function headTemplate(sections, opts, folded) {
    return repeat(sections, (section) => section.key, (section) => {
      if (section.key === "talk") return html`<div class="ws-sec talk">${talkTemplate(section, opts)}</div>`;
      const open = !folded.has(section.key);
      const tokens = tokensText(section.tokens);
      const head = html`<button type="button" class="ws-sec-head" data-ws="section" data-id=${section.key} aria-expanded=${String(open)}><span class="k">${open ? "▾" : "▸"}</span><span class="t">${section.title}</span>${section.meta ? html`<span class="n">${section.meta}</span>` : nothing}${section.twice ? html`<span class="w" title="in the prompt and read again: held twice">· ${section.twice} held twice</span>` : nothing}${tokens ? html`<span class="tk">${tokens}</span>` : nothing}</button>`;
      let body;
      if (section.inner) {
        body = open
          ? html`${section.inner.length ? nothing : html`<div class="ctx-pop-meta">Nothing read yet: the files, memories and URLs this session's turns read show here.</div>`}${section.inner.map((sub) => html`<div class="ctx-pop-meta ws-sub">${sub.title}${sub.meta ? ` · ${sub.meta}` : ""}</div>${labelsTemplate(sub.labels, opts)}${sub.muted.map((m) => rowTemplate(m, opts))}`)}`
          : section.inner.flatMap((sub) => sub.labels.flatMap((l) => l.members)).filter((m) => isLit(m, opts)).map((m) => rowTemplate(m, opts));
      } else {
        body = (open ? section.rows : section.rows.filter((r) => r.kind === "memory" && isLit(r, opts))).map((r) => startRow(r, opts));
      }
      return html`<div class=${`ws-sec ${section.key}${open ? "" : " folded"}`}>${head}${body}</div>`;
    });
  }

  // The line under the header, by lens: a turn lens has its touched line
  // (draw's); the session lens the head line ("in chi's head now · ~X of
  // Y") with parts and the context's tokens, else the size line ("N items ·
  // ctx N %"), so the list never lacks a size. The header itself has none.
  function lensLines(st, set, head, inSession) {
    if (!inSession) return { line: "", size: "" };
    const line = head ? headLine(st.ctxTokens, st.ctxWindow) : "";
    if (line) return { line, size: "" };
    const pct = Number.isFinite(st.ctxPct) ? ` · ctx ${Math.round(st.ctxPct)} %` : "";
    return { line: "", size: `${set.items.length} item${set.items.length === 1 ? "" : "s"}${pct}` };
  }

  // The text the list shows of the context's tokens: the line under the
  // header (the head line or the size line) and the conversation row's tokens.
  function tokenText({ line, size }, head) {
    const talk = head?.find((s) => s.key === "talk");
    return `${line}|${size}|${talk ? tokensText(talk.tokens) : ""}`;
  }

  // The session's folded sections, and a toggle of one.
  // Nothing stored (null, told from a stored []) is the default fold.
  const foldedNow = () => foldedSections(readPref(WS_SECTION_FOLD, session(), null));
  function toggleSection(key) {
    const folded = foldedNow();
    if (folded.has(key)) folded.delete(key);
    else folded.add(key);
    writePref(WS_SECTION_FOLD, session(), JSON.stringify([...folded]));
  }

  // A section's labels: leaves as rows, groups as an opener row and, open,
  // their members.
  function labelsTemplate(labels, opts) {
    return labels.map((label) => {
      if (label.type === "leaf") return rowTemplate(label.members[0], opts);
      const open = openGroup === label.id;
      // A folded group still shows the members the lens lights.
      const lit = opts.touched ? label.members.filter((m) => opts.touched.has(itemKey(m))) : [];
      const lensClass = opts.touched ? (lit.length ? " lit" : " dim") : "";
      const state = label.state && label.state !== "live" ? ` ${label.state}` : "";
      const head = html`<button type="button" class=${`ws-row ws-group-head ${label.kind}${state}${lensClass}`} data-ws="group" data-id=${label.id} aria-expanded=${String(open)} title=${labelTitle(label)}><span class="k">${open ? "▾" : "▸"}</span><span class="t">${label.glyph ? `${label.glyph} ` : ""}${label.text}</span>${label.count ? html`<span class="n">· ${label.count}</span>` : nothing}${label.edited ? html`<span class="e">✎${label.edited}</span>` : nothing}${label.cut ? html`<span class="c" title=${`${label.cut} cut (forgotten or dropped)`}>✂${label.cut}</span>` : nothing}<span class="chev">${open ? "close" : "open"}</span></button>`;
      // A group drops its members that can be, not pending already.
      const droppable = sendLine ? label.members.filter((m) => dropRefusal(m) === "" && !opts.pend.has(steerId(m))) : [];
      const act = droppable.length ? html`<span class="ws-act">${actButton("drop", droppable, { label: `drop ${droppable.length}`, title: "send stubs instead of their reads from the next turn's start" })}</span>` : nothing;
      return html`<div class="ws-ghead">${head}${act}</div>${(open ? label.members : lit).map((m) => rowTemplate(m, { ...opts, group: label }))}`;
    });
  }

  function draw() {
    const now = Date.now();
    const st = state();
    // A lens past the last turn (a seed between a live turn's events) shows the
    // session and is kept: the turn coming back lights it again.
    const at = curLens();
    const inSession = at === null;
    const full = sessionSet();
    const pend = pending();
    const forget = forgetOn(st.llmContext);
    const last = lastTurn();
    // The list's order: last touched first, held while it is open
    // (ws_order.js). Only the list's: rowItem, steer and the rail read the
    // set as it is.
    const set = { ...full, items: heldOrder(full.items, openKeys) };
    // The head view (no parts: today's list); a turn's read of `system/x`
    // lights the start row of `x`, and a prompt memory is never new.
    const head = headSections(set, POP_BUDGET, { parts: st.promptParts, ctxTokens: st.ctxTokens, turns: last + 1, inTurn: !inSession, states: partStates() });
    const inPrompt = promptKeys(head);
    const picked = inSession ? null : turnLens(headItems(set, st.promptParts).filter((item) => !inPrompt.has(itemKey(item))), turnItems(at), at);
    const opts = { session: inSession, now, pend, forget, touched: lensTouched(head, picked?.touched || null) };
    const lines = lensLines(st, set, head, inSession);
    const { line, size } = lines;
    const sections = head ? [] : bodySections(set, POP_BUDGET);
    shownTokens = tokenText(lines, head);
    const turnLabel = last < 0 ? "turn" : `turn ${(at ?? last) + 1}`;
    const added = sendLine ? adding(pend) : [];
    const empty = !set.items.length && !set.muted.length && !added.length;
    const tpl = html`<div class="ctx-pop-head"><strong>working set</strong><span class="ws-lens" role="group" aria-label="Lens"><button type="button" class=${inSession ? "on" : ""} aria-pressed=${String(inSession)} data-ws="lens" data-lens="session">session</button><button type="button" class="arrow" data-ws="lens" data-lens="prev" aria-label="Previous turn" ?disabled=${last < 0 || at === 0}>‹</button><button type="button" class=${!inSession ? "on" : ""} aria-pressed=${String(!inSession)} data-ws="lens" data-lens="turn" ?disabled=${last < 0}>${turnLabel}</button><button type="button" class="arrow" data-ws="lens" data-lens="next" aria-label="Next turn" ?disabled=${inSession || at >= last}>›</button></span>${ringTemplate(st.ctxPct)}<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
      ${picked ? html`<div class="ctx-pop-meta ws-lens-line">turn ${at + 1} touched ${picked.count} · ${picked.fresh} new</div>` : nothing}
      ${line ? html`<div class="ctx-pop-meta ws-head-line">${line}</div>` : nothing}
      ${size ? html`<div class="ctx-pop-meta ws-size-line">${size}</div>` : nothing}
      ${empty && !head ? html`<div class="ctx-pop-meta">Nothing yet: the files, memories and URLs this session's turns read show here.</div>` : nothing}
      ${head ? headTemplate(head, opts, foldedNow()) : repeat(sections, (section) => section.key, (section) => html`<div class="ctx-pop-meta">${section.title}${section.meta ? ` · ${section.meta}` : ""}</div>${labelsTemplate(section.labels, opts)}${section.muted.map((m) => rowTemplate(m, opts))}`)}
      ${added.length ? html`<div class="ctx-pop-meta">adding · ${added.length}</div>${added.map((it) => rowTemplate(it, opts))}` : nothing}
      ${pend.size ? html`<div class="ws-pending" role="status"><span class="ws-pending-t">${pend.size} change${pend.size === 1 ? "" : "s"} pending<span class="ws-pending-when"> · apply at the next turn's start</span></span><button type="button" class="ws-act-b" data-ws="undo-all">undo all</button></div>` : nothing}
      ${sendLine ? html`<form class="ws-add" data-ws="add-form"><input class="ws-add-in" type="text" name="key" placeholder="+ path, memory:ENTRY or URL" aria-label="Add to the working set: a path, memory:ENTRY or a URL" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="go"><button type="submit" class="ws-act-b">add</button></form>` : nothing}
      <div class="ctx-pop-meta ws-hint">${peek ? "A row's ▸ peeks at what chi has of it; the name still opens its ref" : "A file opens its ref"}; a step tag goes to the call.${sendLine ? " Drop sends stubs instead of an item's reads from the next turn; add asks the model to read one first." : ""}${sendLine && forget ? " Pin keeps an item from the model's forget." : ""} Esc closes.</div>`;
    render(tpl, popover.pop);
  }

  // The row at +at+ ({turn, step, row}): the stage's block for the live
  // turn, else the history's.
  function rowAt(at) {
    const sel = `.turn-work[data-turn="${at.turn}"]`;
    const blocks = [...(stageRoot()?.querySelectorAll(sel) || []), ...[...historyEl.querySelectorAll(sel)].reverse()];
    for (const block of blocks) {
      const row = block.querySelector(`.activity-row[data-at="${at.step}.${at.row}"]`);
      if (row) return row;
    }
    return null;
  }

  function jump(at) {
    const row = rowAt(at);
    if (!row) return false;
    if (popover.isOpen()) popover.close();
    showRow(row);
    return true;
  }

  const parseAt = (text) => {
    const [turn, step, row] = String(text).split(".").map(Number);
    return [turn, step, row].every(Number.isInteger) ? { turn, step, row } : null;
  };

  // The item of the list's row +id+ (its steerId): the session's set, the
  // shown turn's.
  function rowItem(id) {
    return sessionSet().items.find((it) => steerId(it) === id) || null;
  }

  // Posts +op+ for the ids (the items' steer words, from the set).
  function steer(op, ids) {
    if (!sendLine || !ids.length) return;
    const all = [...sessionSet().items, ...adding()];
    const byId = new Map(all.map((it) => [steerId(it), it]));
    const items = ids.map((id) => byId.get(id)).filter(Boolean);
    if (items.length) Promise.resolve(sendLine(steerLine(op, items, state().dir))).catch(() => {});
  }

  popover.pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-ws]");
    // A sheet's row: a tap outside its links and buttons opens its strip.
    if (!act && popover.pop.classList.contains("sheet")) {
      const row = e.target.closest(".ws-row[data-ws-id]");
      if (row && !e.target.closest("a, button, .ref")) {
        stripOpen = stripOpen === row.dataset.wsId ? null : row.dataset.wsId;
        draw();
        popover.replace();
      }
      return;
    }
    if (!act) return;
    if (act.dataset.ws === "steer") {
      steer(act.dataset.op, JSON.parse(act.dataset.ids || "[]"));
    } else if (act.dataset.ws === "undo-all") {
      const pend = pending();
      for (const op of STEER_OPS) {
        const ids = [...pend].filter(([, o]) => o === op).map(([id]) => id);
        steer(INVERSE[op], ids);
      }
    } else if (act.dataset.ws === "peek" && peek) {
      const item = rowItem(act.dataset.wsId);
      // One peek at a time across both kinds.
      if (item) { part?.close(); peek.toggle(act.dataset.wsId, item); }
    } else if (act.dataset.ws === "timeline" && onTimeline) {
      const item = rowItem(act.dataset.wsId);
      if (popover.isOpen()) popover.close();
      if (item) onTimeline(item);
    } else if (act.dataset.ws === "jump") {
      const at = parseAt(act.dataset.at);
      if (at) jump(at);
    } else if (act.dataset.ws === "lens") {
      const last = lastTurn();
      const to = act.dataset.lens;
      const here = curLens();
      const next = to === "session" ? null : to === "turn" ? here ?? last : to === "prev" ? (here === null ? last : here - 1) : here === null ? null : here + 1;
      if (next !== null && (next < 0 || next > last)) return;
      lens = next;
      draw();
      popover.replace();
    } else if (act.dataset.ws === "section") {
      toggleSection(act.dataset.id);
      draw();
      popover.replace();
    } else if (act.dataset.ws === "group") {
      openGroup = openGroup === act.dataset.id ? null : act.dataset.id;
      draw();
      popover.replace();
    }
  });

  // A footprint: its step tag jumps, the rest opens that turn's view. Inside
  // a <summary>, the click is cancelled so it doesn't toggle the block.
  function footClick(e) {
    const foot = e.target.closest?.(".ws-foot");
    if (!foot) return;
    if (foot.closest("summary")) e.preventDefault();
    const tag = e.target.closest(".ws-step[data-at]");
    if (tag) {
      const at = parseAt(tag.dataset.at);
      if (at) jump(at);
      return;
    }
    if (popover.isOpen() && popover.opener() === foot) return popover.close();
    lens = Number(foot.dataset.wsTurn);
    popover.open(foot);
  }
  doc.addEventListener("click", footClick);
  doc.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches?.(".ws-foot")) {
      e.preventDefault();
      footClick(e);
    }
  });

  function changed() {
    onChange();
    if (popover.isOpen()) popover.refresh();
  }

  // The pending ops changed: the list and the rail's marks.
  function pendingChanged() {
    changed();
    for (const fn of listeners) fn();
  }

  // The footprints on the page (the history's, the hand-off's) drawn again
  // in place when their items' states changed: the same node (its focus,
  // the popover's opener), its children and label replaced.
  function refreshFootprints() {
    for (const root of [historyEl, stageRoot()]) {
      for (const foot of root?.querySelectorAll(".ws-foot[data-ws-turn]") || []) {
        const ordinal = Number(foot.dataset.wsTurn);
        if (!Number.isInteger(ordinal)) continue;
        const items = turnItems(ordinal);
        if (!items.length || foot.dataset.wsSig === footSig(items)) continue;
        const next = footprintNode(items, ordinal);
        if (!next) continue;
        foot.replaceChildren(...next.childNodes);
        foot.setAttribute("aria-label", next.getAttribute("aria-label"));
        foot.dataset.wsSig = next.dataset.wsSig;
      }
    }
  }

  // A newer server snapshot redraws every form; an older one (a GET that
  // answered after a newer event) is dropped, all but its parts. +how+:
  // newerSnapshot's. The parts (the stale prompt parts) are a GET's word
  // alone: an event's set carries none, so the session's last GET's stay
  // (stale lasts until chi rebuilds its prompt; #sessionChanged and a
  // hand-off ask again), and a GET an event overtook still gives them.
  function takeServer(snapshot, how) {
    let next = newerSnapshot(server, snapshot, how);
    const same = !!server && serverOf === session();
    if (next === server) {
      if (how?.event || !same || !Array.isArray(snapshot?.items) || partsSig(snapshot.parts) === partsSig(server.parts)) return;
      next = withParts(server, snapshot.parts);
    } else if (how?.event && same && !("parts" in next) && server.parts) {
      next = withParts(next, server.parts);
    }
    server = next;
    serverOf = session();
    changed();
    refreshFootprints();
    for (const fn of listeners) fn();
    // An open peek asks again on an event (a GET answers the open itself),
    // when its item's server signature changed (ws_peek.js refresh).
    if (how?.event && popover.isOpen()) peek?.refresh();
  }

  // +snapshot+ with +parts+ (none: without the field).
  function withParts(snapshot, parts) {
    const { parts: _drop, ...rest } = snapshot;
    return Array.isArray(parts) && parts.length ? { ...rest, parts } : rest;
  }

  // The server's set for the open session, asked again; an answer for a
  // session no longer open is dropped.
  function fetchServer() {
    const id = session();
    if (!getWorkingSet || !id) return;
    const asked = events;
    const still = stillOn(session, id);
    Promise.resolve()
      .then(() => getWorkingSet(id))
      .then((snapshot) => { if (still()) takeServer(snapshot, { overtaken: events !== asked }); })
      .catch(() => {});
  }

  return {
    // A session's history drawn anew: its turns' sets (+list+: [{items,
    // prompt}]), no running turn yet; the chip's dot starts off.
    seed(list) {
      turns = list.slice();
      live = null;
      // The snapshot's replay (after this) brings the queued lines again.
      queued.clear();
      queuedOf = session();
      stripOpen = null;
      // Another session's snapshot goes; the same session's (a resync, after
      // a steer from the list) stays until the newer one comes, and so does
      // the open list.
      if (serverOf !== session()) {
        if (popover.isOpen()) popover.close();
        server = null;
        serverOf = session();
      } else if (popover.isOpen()) {
        popover.refresh();
      }
      openedCount = sessionSet().items.length;
      refreshFootprints();
      fetchServer();
    },
    // The session's strategy changed (/llm-context's command_ran): the open
    // list redraws, its pin buttons shown only under forget (forgetOn).
    strategyChanged() {
      if (popover.isOpen()) popover.refresh();
    },
    // Prompt memories changed; the open session list reads them from state.
    // A new prompt build (its parts' heads or digests) asks the server's set
    // again: its stale states are the build's.
    sessionChanged() {
      const sig = builtSigOf(state().promptParts);
      const rebuilt = builtOf === session() && builtSig !== null && sig !== builtSig;
      builtSig = sig;
      builtOf = session();
      if (rebuilt) fetchServer();
      if (popover.isOpen()) popover.refresh();
    },
    // The context's tokens or window changed (a chunk, a context_status):
    // the open list redraws only when what it shows of them changes.
    tokensChanged() {
      if (!popover.isOpen()) return;
      const st = state();
      const inSession = curLens() === null;
      const set = sessionSet();
      const head = headSections(set, POP_BUDGET, { parts: st.promptParts, ctxTokens: st.ctxTokens, turns: lastTurn() + 1, inTurn: !inSession, states: partStates() });
      if (tokenText(lensLines(st, set, head, inSession), head) !== shownTokens) popover.refresh();
    },
    // A :working_set_updated event's set ({items, at}).
    update(snapshot) {
      events += 1;
      takeServer(snapshot, { event: true });
    },
    // +fn()+ runs after each new server snapshot and each change of the
    // pending ops (the rail's redraw).
    onServer(fn) { listeners.add(fn); },
    // A command queued for after the running turn (its command_queued,
    // waits "turn_end"): a steer line is pending until its command_ran.
    commandQueued(event) {
      if (queuedOf !== session()) {
        queued.clear();
        queuedOf = session();
      }
      if (event?.waits !== "turn_end" || !event.command_id || !parseSteerLine(event.line)) return;
      queued.set(event.command_id, event.line);
      pendingChanged();
    },
    // A command ran (or was dropped): its line is no longer pending.
    commandRan(event) {
      if (event?.command_id && queued.delete(event.command_id)) pendingChanged();
    },
    // The steer lines pending (for the specs and the rail).
    pending: () => pending(),
    // The running turn's items (its model +turn+), its ordinal the next
    // turn's; the chip follows.
    liveItems(turn, prompt = "") {
      const ordinal = turns.length;
      const items = itemsOfTurn(turn, ordinal);
      const before = live?.items.length ?? -1;
      live = { ordinal, items, prompt };
      if (items.length !== before) changed();
      return { items: lit(items), ordinal };
    },
    // The rail's first-sight times, for the popover's fresh rows.
    setSeen(fn) { seenAt = fn; },
    // The running turn hands off: its set joins the turns; its footprint
    // (null: it touched nothing) goes into its block's summary.
    handOff(turn, prompt = "") {
      const ordinal = turns.length;
      const items = itemsOfTurn(turn, ordinal);
      turns.push({ items, prompt });
      live = null;
      changed();
      // A turn's end: the stale states asked again when there are some, or the list is open.
      if (server?.parts || popover.isOpen()) fetchServer();
      return footprintNode(lit(items), ordinal);
    },
    // The running turn left without a hand-off (a reset): forgotten.
    release() {
      if (!live) return;
      live = null;
      if (lens !== null && lens > lastTurn()) lens = null;
      changed();
    },
    // The rail opens the running turn's view.
    openTurn(anchor) {
      if (popover.isOpen() && popover.opener() === anchor) return popover.close();
      lens = lastTurn() < 0 ? null : lastTurn();
      popover.open(anchor);
      openedCount = sessionSet().items.length;
      onChange();
    },
    // The session bar's chip: {n, changed} (the dot), "set 0" while the
    // set is empty. Opening it clears the dot.
    chip() {
      const n = sessionSet().items.length;
      if (popover.isOpen()) openedCount = n;
      return { n, changed: n !== openedCount };
    },
    // The peek's content changed: the open list redraws and places itself.
    peekChanged() {
      if (!popover.isOpen()) return;
      draw();
      popover.replace();
    },
    jump,
    // The session's set as the list shows it (overlaid), for the reader.
    items: () => sessionSet().items,
    // +item+'s server signature (working_set.js serverSig), for the peek and the reader.
    serverSig: (item) => serverSig(server, item),
    // The list opened at the session bar's chip (the reader's ‹ Set).
    openList() {
      const chip = infoEl.querySelector(".ws-chip");
      if (!chip) return;
      lens = null;
      popover.open(chip);
    },
    ctxPct: () => state().ctxPct,
    isOpen: () => popover.isOpen(),
    popover,
  };
}
