// The quiet signal's clocks (stage_view.js; stage_stall.js draws the
// signal): the turn's last event, since when the stream isn't live, the
// grace after the page shows again. Its own module: new exports go in new
// modules, and an existing module's factory keeps its signature
// (web-frontend.md).
import { GRACE_MS, stallState } from "./stage_stall.js";

// +stall+: the drawer (stage_stall.js createStageStall). Its inputs
// (stage_view.js's): +clock+() the page's time, +streamLive+() the
// session's stream is open, +timingNote+() what the turn waits on
// (live_timing.js note), +serverGen+() a joiner's generation; +held+() the
// turn the stage holds (null: none), +ended+() it has ended, +pending+() a
// card blocks it.
export function createStageQuietClock({
  stall, clock = () => Date.now(), streamLive = () => true, timingNote = () => "", serverGen = () => null,
  held = () => null, ended = () => false, pending = () => false,
}) {
  let lastEventAt = 0;
  let downSince = null; // null: the stream is live
  let graceUntil = 0;

  // At +nowMs+ (the tick's, a refresh's): what the held turn's silence says.
  function tick(nowMs, blocked = pending()) {
    const turn = held();
    if (!turn) return;
    if (streamLive()) downSince = null;
    else downSince ??= nowMs;
    stall.draw(stallState({
      turn, lastEventAt, nowMs, blocked, note: timingNote() || "", ended: ended(), graceUntil, serverGen: serverGen(),
      streamDownMs: downSince === null ? null : nowMs - downSince,
    }));
  }

  // A turn event arrived (a replay's too), or a turn started: the silence
  // starts over, and a stall shown clears at once.
  function alive() {
    lastEventAt = clock();
    if (stall.level()) tick(lastEventAt);
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) graceUntil = clock() + GRACE_MS;
  });

  // The turn left the stage: the signal goes, the stream's clock too.
  function reset() {
    stall.reset();
    downSince = null;
  }

  return { tick, alive, reset };
}
