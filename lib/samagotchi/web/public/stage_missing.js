// A running session whose stage shows nothing of its turn (docs/internals/web-frontend.md,
// "A running session without a turn"). At the points a turn could have been
// drawn — the end of a render (session_view.js), the hand-off and the end of a
// fold (stage_view.js's clearStage) — and again on a resize, a composer that
// changed size or a status change, it does two things:
//   the safety net: the session's status runs and the stage holds no turn, so
//   the stage keeps its bare status row ("running", Stop turn) instead of
//   vanishing (runningWithoutTurn, stage_view.js), and a status that leaves
//   running takes that row with it;
//   the diagnostic: the stage is marked `data-stage-missing` ("1" for no turn,
//   "covered" for a turn the composer card is over) and, once per session
//   visit, a console.warn with counts only — never a prompt, a message or an
//   answer — saying what the read had (live_read, current_turn, the replay's
//   event types and their counts, the last replayed end event's turn id beside
//   the running turn's) and where the stage sat (its status row's top and
//   bottom, the composer's top, the window's height, the composer's saved floor
//   and fold). The covered case is reported only: a stage the user made tall is
//   their own doing, and the net is for a stage that shows nothing at all.
//
// The numbers come from getBoundingClientRect at the call; the pure functions
// take them as arguments, so a spec can pass its own. Its own module: new
// exports go in new modules (web-frontend.md).
import { readStored } from "./storage.js";
import { COMPOSER_FOLD_KEY } from "./composer_fold.js";
import { GRIP_KEY } from "./composer_grip.js";

// The replay events that end a turn.
const ENDS = ["turn_completed", "turn_canceled", "turn_failed"];

// What a show read said, in counts.
export function readCounts(data = {}) {
  const replay = Array.isArray(data.replay) ? data.replay : [];
  const events = {};
  let lastEndTurn = null;
  for (const event of replay) {
    events[event.type] = (events[event.type] || 0) + 1;
    if (ENDS.includes(event.type)) lastEndTurn = event.turn_id ?? null;
  }
  return {
    liveRead: data.live_read ?? null,
    currentTurn: data.current_turn?.turn_id ?? null,
    replay: replay.length,
    events,
    lastEndTurn,
  };
}

// The stage's status row out of sight: wholly above or below the window, or
// below the composer card's top edge (the dock puts the stage above it:
// index.html, .turn-stage). A hidden stage is hidden, not covered; a row with
// no measured height (a stub, a stage not yet laid out) says nothing.
export function stageCovered({ hidden, stageTop, stageBottom, composerTop, viewport }) {
  if (hidden) return false;
  if (stageBottom > stageTop && (stageBottom <= 0 || stageTop >= viewport)) return true;
  return composerTop !== null && stageTop > composerTop;
}

// Why the stage shows nothing of a turn, or null when it shows it: "none" (no
// turn in the stage), "covered" (it holds one, out of sight).
export function missingReason({ status, holds, hidden, stageTop, stageBottom, composerTop, viewport }) {
  if (status !== "running") return null;
  if (!holds) return "none";
  return stageCovered({ hidden, stageTop, stageBottom, composerTop, viewport }) ? "covered" : null;
}

// The console line: counts, no text from the session.
export function missingLine({ session, reason, counts, stage, composer }) {
  const events = Object.entries(counts.events || {}).map(([type, n]) => `${type}=${n}`).join(" ") || "none";
  return `stage-missing ${session || "none"} (${reason}) live_read=${counts.liveRead ?? "unknown"} ` +
    `current_turn=${counts.currentTurn ?? "none"} replay=${counts.replay} events=${events} ` +
    `last_end=${counts.lastEndTurn ?? "none"} vs turn=${counts.currentTurn ?? "none"} ` +
    `stage_row=${stage.stageTop}..${stage.stageBottom} composer_top=${stage.composerTop} window=${stage.viewport} ` +
    `composer_floor=${composer.floor ?? "unset"} composer_fold=${composer.fold ?? "unset"}`;
}

// +store+, +turnDom+ the page's views; +composerEl+ the composer card's box;
// +win+ the page's window; +warn+ where the line goes.
// @return {note(data), check()}
export function createStageMissing({ store, turnDom, composerEl, win = globalThis, warn = (line) => console.warn(line) }) {
  const warned = new Set();
  let counts = null;

  function geometry() {
    const stage = turnDom.root;
    const row = stage.querySelector(".ts-status") || stage;
    const stageRect = row.getBoundingClientRect?.() || { top: 0, bottom: 0 };
    const composerRect = composerEl?.getBoundingClientRect?.() || { top: null, bottom: null };
    return {
      hidden: !!stage.hidden,
      stageTop: stageRect.top ?? 0,
      stageBottom: stageRect.bottom ?? 0,
      // A folded composer shows nothing (composer.css), so it has no top to
      // cover with; neither has one not laid out yet.
      composerTop: composerRect.bottom > composerRect.top ? composerRect.top : null,
      viewport: win?.innerHeight ?? 0,
    };
  }

  // The stage's state at one of the points a turn could have been drawn.
  function check() {
    const stage = turnDom.root;
    const status = store.current.status;
    if (status !== "running") {
      delete stage.dataset.stageMissing;
      // A status that left running takes the bare row with it: setTurnRunning
      // is not the only writer (turnEndStatus and the hub change the status too).
      turnDom.runningWithoutTurn?.(false);
      return null;
    }
    // The safety net: a session that runs keeps its status row (running and
    // Stop turn) rather than showing nothing. It is a no-op when the stage
    // holds or is folding a turn (stage_view.js's runningWithoutTurn).
    if (!turnDom.holds()) turnDom.runningWithoutTurn?.(true);
    const where = geometry();
    const reason = missingReason({ status, holds: turnDom.holds(), ...where });
    if (!reason) {
      delete stage.dataset.stageMissing;
      return null;
    }
    stage.dataset.stageMissing = reason === "covered" ? "covered" : "1";
    const session = store.selected;
    if (!warned.has(session)) {
      warned.add(session);
      warn(missingLine({
        session, reason, counts: counts || readCounts({}),
        stage: where,
        composer: {
          top: stage.composerTop,
          floor: readStored(GRIP_KEY),
          fold: readStored(COMPOSER_FOLD_KEY),
        },
      }));
    }
    return reason;
  }

  // A status write redraws the bar: only a change needs the stage looked at,
  // and only one away from running. A turn that runs is drawn by the render,
  // the hand-off or the fold; a status that comes to running before the replay
  // is drawn would warn about a stage not yet filled.
  let lastStatus = null;
  function checkOnStatus() {
    if (store.current.status === lastStatus) return null;
    lastStatus = store.current.status;
    if (store.current.status === "running") return null;
    return check();
  }

  return { note: (data) => { counts = readCounts(data); }, check, checkOnStatus };
}
