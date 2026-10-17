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

// The open session's worker runs an older chi than the newest installed:
// a badge, with Restart when the worker can (else the stop command).
// @param id the open session's id (null: none)
// @param state the open session's fields (session_state.js)
// @param versions {served, installed}: the chi serving the page, the newest
export function workerBadgeFor(id, state, versions) {
  if (!id || state.owner !== "worker") return null;
  return workerBadge({ workerVersion: state.workerVersion, features: state.workerFeatures,
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
// @param now the clock (ms)
export function infoBarModel({ id, state, sessions, chain, cardTitle, badge, restarting, running, now }) {
  const tokens = state.timing.tokens;
  const ctxTip = ctxBarTip(tokens, state.timing.memoryIndex,
                           { tokens: state.ctxWindow, source: state.ctxWindowSource, pct: state.ctxPct,
                             budget: state.llmContext?.budget_tokens }, state.timing.modelSegments);
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
    copied: now - state.attachCopiedAt < 2000,
    status: state.status,
    model: modelLabel(state.model, ...(state.served || [])),
    // A link of a session chain: ← the previous link, → the next one (each
    // only while the list holds it).
    chain: { prev: chainLinkView(chain.prev, cardTitle, selfIso), next: chainLinkView(chain.next, cardTitle, selfIso) },
    parent: parentChip ? { id: state.parentId, title: parentChip.title } : null,
    // A parent names its delegates; the link opens all sessions.
    kids: childrenSummary({ id }, sessions),
    llmContext: state.llmContext,
    thinking: state.thinking,
    reasoningHistory: state.reasoningHistory,
    // The tools chip (toolkit_chip.js): null on full.
    toolkit: state.toolkit,
    // The model notes the session's prompt carried.
    notes: promptNotesChip(state.promptNotes),
    memories: state.usedMemories,
    preloaded: state.preloadedMemories,
    muted: state.mutedMemories,
    dir: state.dir,
    ctx: { text: ctxBarText(state.ctxPct, state.ctxWindowSource), tip: ctxTip },
    speed: speedTextNow ? { text: speedTextNow, tip: `Decode speed of the last generation${avgSpeed ? `; session average ${avgSpeed}` : ""}` } : null,
    clock: sessionDuration === null ? "" : `session ${formatDuration(sessionDuration)}`,
    worker: badge ? { badge, busy: restarting } : null,
  };
}

// The whole bar for the open session +id+ (null: the start page, no line).
// @param sessions the page's list; +continuing+, +restarting+: Sets of ids
// @return {buttons, bar}
export function sessionBar({ id, state, sessions, versions, cardTitle, continuing, restarting, streaming, running, now }) {
  const chain = id ? chainNeighbours(sessions, id, { continues: state.continues }) : { prev: null, next: null };
  const archived = !!sessions.find((s) => s.id === id)?.archived;
  const buttons = infoButtons({ id, state, chain, archived, continuing: continuing.has(id), streaming });
  if (!id) return { buttons, bar: null };
  const badge = workerBadgeFor(id, state, versions);
  const bar = infoBarModel({ id, state, sessions, chain, cardTitle, badge, restarting: restarting.has(id), running, now });
  return { buttons, bar };
}
