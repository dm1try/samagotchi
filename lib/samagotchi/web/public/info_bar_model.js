// What the session bar shows for the open session, as plain data: the info
// line's model (info_bar.js renders it) and its buttons' states (continue,
// delete, archive, stop), from the page's session state (session_state.js),
// its list and its in-flight actions. Pure: app.js's updateInfoBar applies
// it, every second while a turn runs (the session clock).
import { canStopSession, childrenSummary, delegatedBy, modelLabel, promptNotesChip } from "./format.js";
import { chainClock, chainDate, chainNeighbours } from "./chains.js";
import { ctxBarText, ctxBarTip, lastSpeedText, speedText } from "./ctx.js";
import { formatDuration, sessionDurationNow } from "./timing.js";
import { workerBadge } from "./update_notice.js";
import { chipModel as settingsChipModel } from "./settings_chip.js";

// Every chip and button of the session bar (#infoBar), one item per key:
// {key, selector (its element in #infoBar), group (the .meta's identity,
// setup, relations, trail as info_bar.js draws them; actions: #infoActions
// and ⋯), rank, phone, compact, menuOrder}.
//   rank: the desktop fold order, a higher rank stays longer; "pinned"
//     never folds, "menu" is never on the row. Items of one rank fold together.
//   phone: "row" (a row candidate at the phone width) or "menu".
//   compact: a smaller row form tried before the item folds (⚙ alone).
//   menuOrder: its place in ⋯ (more_sheet.js ROW_KEYS, ACTION_KEYS: the
//     actions group's are the actions, the others rows); null: no row (status,
//     ⋯ itself; ctx, speed, time and the folder are its telemetry line).
// Data for the fold (docs/internals/web-frontend.md): shaped so a bundle or
// the user can add an item with a rank later.
export const BAR_ITEMS = Object.freeze([
  { key: "status", selector: ".status", group: "identity", rank: "pinned", phone: "row", menuOrder: null },
  { key: "ctx", selector: ".ctx", group: "identity", rank: "pinned", phone: "row", menuOrder: null },
  { key: "more", selector: "#infoMoreBtn", group: "actions", rank: "pinned", phone: "row", menuOrder: null },
  { key: "id", selector: ".id", group: "identity", rank: 12, phone: "menu", menuOrder: 1 },
  { key: "continue", selector: "#infoContinueBtn", group: "actions", rank: 11, phone: "menu", menuOrder: 1 },
  { key: "settings", selector: ".settings-chip", group: "setup", rank: 10, phone: "row", compact: true, menuOrder: 3 },
  { key: "worker", selector: ".worker-badge", group: "trail", rank: 9, phone: "menu", menuOrder: 14 },
  { key: "speed", selector: ".speed", group: "identity", rank: 8, phone: "row", menuOrder: null },
  { key: "stop", selector: "#infoStopBtn", group: "actions", rank: 7, phone: "menu", menuOrder: 3 },
  { key: "prev", selector: ".chain-prev", group: "relations", rank: 6, phone: "menu", menuOrder: 9 },
  { key: "next", selector: ".chain-next", group: "relations", rank: 6, phone: "menu", menuOrder: 10 },
  { key: "pruned", selector: ".chain-pruned", group: "relations", rank: 6, phone: "menu", menuOrder: 8 },
  { key: "parent", selector: ".parent", group: "relations", rank: 6, phone: "menu", menuOrder: 11 },
  { key: "time", selector: ".session-time", group: "identity", rank: 5, phone: "menu", menuOrder: null },
  { key: "model", selector: ".model-name", group: "setup", rank: 4, phone: "menu", menuOrder: 2 },
  { key: "delegates", selector: ".children-chip", group: "relations", rank: 3, phone: "menu", menuOrder: 12 },
  { key: "participants", selector: ".participants-chip", group: "relations", rank: 3, phone: "menu", menuOrder: 7 },
  { key: "workingSet", selector: ".ws-chip", group: "setup", rank: 2, phone: "menu", menuOrder: 5 },
  { key: "memories", selector: ".mem-chip", group: "setup", rank: 2, phone: "menu", menuOrder: 6 },
  { key: "notes", selector: ".notes-chip", group: "setup", rank: 2, phone: "menu", menuOrder: 13 },
  { key: "toolkit", selector: ".tools-chip", group: "setup", rank: 1, phone: "menu", menuOrder: 4 },
  { key: "dir", selector: ".dir", group: "trail", rank: 1, phone: "menu", menuOrder: null },
  { key: "archive", selector: "#infoArchiveBtn", group: "actions", rank: "menu", phone: "menu", menuOrder: 2 },
  { key: "delete", selector: "#infoDeleteBtn", group: "actions", rank: "menu", phone: "menu", menuOrder: 4 },
].map((item) => Object.freeze({ compact: false, ...item })));

// The BAR_ITEMS keys the open session's bar draws (info_bar.js infoBarHtml
// for +bar+, the buttons app.js shows from +buttons+), in BAR_ITEMS' order;
// [] without a session.
export function barItemKeys(bar, buttons) {
  if (!bar) return [];
  const has = {
    status: true, ctx: true, more: true, id: true, time: true, model: true, dir: true,
    continue: !!buttons?.continue?.shown, stop: !!buttons?.stop?.shown,
    archive: !!buttons?.archive?.shown, delete: !!buttons?.delete?.shown,
    settings: !!(bar.settings && settingsChipModel(bar.settings)),
    worker: !!bar.worker?.badge,
    speed: !!bar.speed,
    prev: !!bar.chain?.prev,
    next: !!bar.chain?.next,
    pruned: !!bar.chain?.pruned && !bar.chain?.prev,
    parent: !!bar.parent,
    delegates: !!bar.kids,
    participants: !!bar.participants,
    workingSet: !!bar.workingSet?.chip,
    memories: !bar.workingSet && (bar.memories || []).length > 0,
    notes: !!bar.notes,
    toolkit: !!bar.toolkit,
  };
  return BAR_ITEMS.filter((item) => has[item.key]).map((item) => item.key);
}

// The speed chip's placeholder before the session's first generation.
export const SPEED_NONE = "– tok/s";

// The open session's worker runs an older chi than the newest installed:
// a badge, with Restart when the worker can (else the stop command).
// @param id the open session's id (null: none)
// @param state the open session's fields (session_state.js)
// @param versions {served, installed}: the chi serving the page, the newest
export function workerBadgeFor(id, state, versions) {
  if (!id || state.owner !== "worker") return null;
  return workerBadge({ workerVersion: state.workerVersion, compatibility: state.workerCompat, features: state.workerFeatures,
                       installed: versions.installed, served: versions.served, sessionId: id });
}

// A chain's link (chains.js chainNeighbours) as the info bar's ← / →
// shows it (info_bar.js chainLinkTemplate), or null. Its date: its local
// HH:MM when it started on the open link's day (+selfIso+: the open
// session's created_at; the day is implied), else its YYYY-MM-DD; its
// stamp (the tooltip's) always both. +cardTitle+: the lists' title for a
// session (a chain's opener reads its first link's).
export function chainLinkView(link, cardTitle, selfIso = null) {
  if (!link) return null;
  const iso = link.session?.created_at;
  const day = chainDate(iso);
  const clock = chainClock(iso);
  return { id: link.id, date: day && day === chainDate(selfIso) ? clock : day, stamp: day ? `${day} ${clock}` : "",
           preview: link.session ? cardTitle(link.session) : "", archived: !!link.session?.archived };
}

// The bar's buttons: continue (not on a link continued already, which has
// its → link, nor a terminal's session; "continuing…" while one runs),
// delete, archive (or unarchive), stop (while a worker runs the session).
export function infoButtons({ id, state, chain, archived, continuing, streaming }) {
  const busy = !!id && continuing;
  return {
    continue: { shown: !!id && !chain.next && state.owner !== "tui", disabled: busy, text: busy ? "continuing…" : "continue →" },
    delete: { shown: !!id },
    archive: {
      shown: !!id,
      archived,
      text: archived ? "unarchive" : "archive",
      title: archived ? "Unarchive: back to the lists" : "Archive: hide from the lists, keep for good",
    },
    stop: { shown: !!id && canStopSession({ owner: state.owner, streaming }) },
  };
}

// The info line's model (info_bar.js renderInfoBar's +bar+).
// @param id the open session's id
// @param state the open session's fields (session_state.js)
// @param sessions the page's list (allSessions: archived ones too)
// @param chain chainNeighbours' {prev, next} for +id+
// @param cardTitle (session) => the lists' title for it
// @param badge workerBadgeFor's, or null
// @param restarting whether this session's Restart is under way
// @param running whether its turn runs (the session clock ticks)
// @param waiting whether the session waits on the user (app.js sessionWaits)
// @param workingSet web.working_set on: the chip's {n, changed} (n 0 while
//   the set is empty); undefined: off (the mem chip shows)
// @param participants the participants chip (participants_panel.js
//   chipModel), null before the list is read
export function infoBarModel({ id, state, sessions, chain, cardTitle, badge, restarting, running, waiting = false, workingSet = undefined, participants = null }) {
  const tokens = state.timing.tokens;
  const ctxTip = ctxBarTip(tokens, state.timing.memoryIndex,
                           { tokens: state.ctxWindow, source: state.ctxWindowSource, pct: state.ctxPct,
                             budget: state.llmContext?.budget_tokens, afterSwitch: state.ctxUnknownAfterSwitch },
                           state.timing.modelSegments, state.timing.side);
  const speedTextNow = lastSpeedText(tokens);
  const avgSpeed = speedText(tokens?.avg_decode_tps, tokens?.tps_source);
  const sessionDuration = sessionDurationNow(state.timing, running);
  // A delegated session names its parent, as a link to it.
  // The open link's start: the payload's, else its list entry's (a fresh
  // link may not be listed yet: then neither, and its links show dates).
  const selfIso = state.createdAt || sessions.find((x) => x.id === id)?.created_at || null;
  const parentChip = delegatedBy(state.parentId, sessions.find((x) => x.id === state.parentId) || null);
  return {
    id,
    // Its turn runs but a card blocks it: the word `chi sessions list` has for it.
    status: running && waiting ? "waiting" : state.status,
    model: modelLabel(state.model, ...(state.served || [])),
    // A link of a session chain: ← the previous link, → the next one (each
    // only while the list holds it).
    // +pruned+: the link before this one is gone (a schedule pruned it).
    chain: { prev: chainLinkView(chain.prev, cardTitle, selfIso), next: chainLinkView(chain.next, cardTitle, selfIso),
             pruned: !!chain.pruned },
    parent: parentChip ? { id: state.parentId, title: parentChip.title } : null,
    // A parent names its delegates; the link opens all sessions.
    kids: childrenSummary({ id }, sessions),
    // The ⚙ chip (settings_chip.js): the three settings' summaries.
    settings: { thinking: state.thinking, reasoningHistory: state.reasoningHistory, llmContext: state.llmContext },
    // The 🧰 chip (toolkit_chip.js): the session's kit (null on full) and
    // config's default.
    toolkit: { summary: state.toolkit, defaultKit: state.toolkitDefault },
    // The model notes the session's prompt carried.
    notes: promptNotesChip(state.promptNotes),
    memories: state.usedMemories,
    // On, the working set's chip stands in the mem chip's place.
    workingSet: workingSet === undefined ? null : { chip: workingSet },
    participants,
    preloaded: state.preloadedMemories,
    muted: state.mutedMemories,
    dir: state.dir,
    ctx: { text: ctxBarText(state.ctxPct, state.ctxWindowSource), tip: ctxTip },
    // From the session's start: a placeholder until the first generation's
    // speed, so it doesn't join the line mid-turn.
    speed: speedTextNow ? { text: speedTextNow, tip: `Decode speed of the last generation${avgSpeed ? `; session average ${avgSpeed}` : ""}`, empty: false }
      : { text: SPEED_NONE, tip: "Decode speed of the last generation: none yet", empty: true },
    // A session with no turn yet has no time of its own: the placeholder, not "0ms".
    // A running first turn still ticks from 0.
    clock: sessionDuration === null || (!running && sessionDuration === 0) ? "" : formatDuration(sessionDuration),
    worker: badge ? { badge, busy: restarting } : null,
  };
}

// The whole bar for the open session +id+ (null: the start page, no line).
// @param sessions the page's list; +continuing+, +restarting+: Sets of ids
// @return {buttons, bar}
export function sessionBar({ id, state, sessions, versions, cardTitle, continuing, restarting, streaming, running, waiting = false, workingSet = undefined, participants = null }) {
  const chain = id ? chainNeighbours(sessions, id, { continues: state.continues }) : { prev: null, next: null };
  const archived = !!sessions.find((s) => s.id === id)?.archived;
  const buttons = infoButtons({ id, state, chain, archived, continuing: continuing.has(id), streaming });
  if (!id) return { buttons, bar: null };
  const badge = workerBadgeFor(id, state, versions);
  const bar = infoBarModel({ id, state, sessions, chain, cardTitle, badge, restarting: restarting.has(id), running, waiting, workingSet, participants });
  return { buttons, bar };
}
