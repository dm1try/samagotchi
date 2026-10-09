// The running turn's timing line ("turn 3 running · 4.1s", then "turn 3 ·
// 4.1s" at its end) and its one-second ticker, apart from app.js: the line's
// element, the turn id it is for, the number it shows, what the turn waits
// on (a provider retry, plugins' setup) and how many turns this page saw
// end. The DOM, the clock and the interval come in, so `node --test` drives
// it with a fake element.
import { elapsedSince, liveDurationText, turnTimingText } from "./timing.js";

// The live line's text, or null when the turn's start is unknown. +inStage+:
// the stage's status row already says the turn runs, so the line drops its
// own "running" there. The duration is the live one (never "0ms": under a
// second it shows tenths).
export function liveLineText({ number, startedAt, note = "", inStage = false }, now = Date.now()) {
  const duration = elapsedSince(startedAt, now);
  if (duration === null) return null;
  const turn = Number.isInteger(number) && number > 0 ? `turn ${number}` : "turn";
  return `${turn}${!inStage ? " running" : ""} · ${liveDurationText(duration)}${note ? ` · ${note}` : ""}`;
}

// The live ticker's interval at +elapsedMs+ into the turn: 200 ms during the
// first ten seconds (the live text counts up from the first second), then
// the one-second tick.
export function liveTickMs(elapsedMs) {
  return Number(elapsedMs) < 10000 ? 200 : 1000;
}

// The record a turn-end read finishes its line with: the one with the
// turn's id; no id (an older worker's events): the last one.
export function lineRecord(records, turnId) {
  return turnId ? records.find((r) => r.id === turnId) : records[records.length - 1];
}

// +timing+()      the open session's timing (normalizeTiming's shape): its
//                 activeTurn is set at the start and cleared at the end;
// +place+(el)     puts a new line in the page, true when that is the stage's
//                 status row (the line never moves mid-turn);
// +makeLine+()    a new element for the line;
// +onTick+()      after every tick and end (the info bar's session clock).
export function createLiveTiming({
  timing,
  place,
  makeLine = () => document.createElement("div"),
  onTick = () => {},
  now = () => Date.now(),
  every = (fn, ms) => setInterval(fn, ms),
  cancel = (handle) => clearInterval(handle),
}) {
  let el = null;
  // The running turn's id (turn_started's turn_id, the id of its timing
  // record), so a turn-end re-read finishes that turn's line with that
  // turn's record, whatever started since.
  let turnId = null;
  let number = null;
  // What the running turn waits on, after its live text; "" when it
  // streams again.
  let note = "";
  let inStage = false;
  let ticker = null;
  // The turns this page saw end: the records of its last full render, +1 at
  // each turn's end, never fewer than a merge brought. The live line numbers
  // the next one, so a turn queued behind another reads its own number while
  // the other's re-read is still out.
  let ended = 0;
  // The ticker's current interval, so a tick that crossed the 10 s boundary
  // re-arms it at the slower one.
  let tickerMs = null;

  function stopTicker() {
    if (ticker !== null) {
      cancel(ticker);
      ticker = null;
      tickerMs = null;
    }
  }

  function armTicker(ms) {
    stopTicker();
    ticker = every(tick, ms);
    tickerMs = ms;
  }

  function tick() {
    const startedAt = timing().activeTurn?.started_at;
    const text = liveLineText({ number, startedAt, note, inStage }, now());
    if (el && text !== null) el.textContent = text;
    onTick();
    // The interval follows the elapsed time: 200 ms while the line counts
    // up from the first second, one a second once it is on whole seconds.
    if (ticker !== null) {
      const elapsed = elapsedSince(startedAt, now());
      const ms = elapsed === null ? tickerMs : liveTickMs(elapsed);
      if (ms !== tickerMs) armTicker(ms);
    }
  }

  return {
    get el() { return el; },
    get turnId() { return turnId; },
    // The replayed turn_started of a re-render carries no id: the running
    // turn's record's.
    set turnId(id) { turnId = id; },
    get ended() { return ended; },
    set ended(n) { ended = n; },
    get ticking() { return ticker !== null; },

    start(startedAt = new Date(now()).toISOString(), id = null) {
      stopTicker();
      timing().activeTurn = id ? { id, started_at: startedAt } : { started_at: startedAt };
      turnId = id || null;
      // The turns ended so far, so this one comes next.
      number = ended + 1;
      note = "";
      el = makeLine();
      el.className = "turn-timing live";
      inStage = !!place(el);
      tick();
      armTicker(liveTickMs(0));
    },

    tick,

    // Set (or clear, "") what the running turn waits on.
    setNote(text) {
      if (note === text) return;
      note = text;
      if (timing().activeTurn) tick();
    },

    // The turn ended: the line stops with its elapsed time (a canceled turn's
    // says so, as a reload's does), numbered as it ran until a re-read
    // (finishLine) has the record.
    finish({ canceled = false } = {}) {
      const duration = elapsedSince(timing().activeTurn?.started_at, now());
      if (el && duration !== null) {
        note = "";
        el.classList.remove("live");
        el.textContent = turnTimingText(number, duration, { canceled });
      }
      timing().activeTurn = null;
      stopTicker();
      onTick();
    },

    // The line and the turn a turn-end read is for, taken before its await:
    // a turn queued behind this one may start (a new live line) meanwhile.
    capture() { return { el, turnId }; },

    // Finish the line a turn-end read captured (+line+: {el, turnId}) with
    // that turn's record: its place in the records and its duration (a
    // canceled one says so). No record: the line stays as the turn's end
    // left it. The ticker stops only if that line is still the live one.
    finishLine(line) {
      const records = timing().turnRecords;
      const record = lineRecord(records, line.turnId);
      if (line.el === el) {
        timing().activeTurn = null;
        stopTicker();
      }
      const duration = Number(record?.duration_ms);
      if (line.el && record && Number.isFinite(duration)) {
        line.el.classList.remove("live");
        line.el.textContent = turnTimingText(records.indexOf(record) + 1, duration, { canceled: record.status === "canceled" });
      }
      onTick();
    },

    // A new turn starts: the old line (finished or not) is no longer the
    // live one.
    detach() {
      stopTicker();
      el = null;
    },

    // The session (or its rendering) starts over.
    drop() {
      stopTicker();
      el = null;
      turnId = null;
    },
  };
}
