// The open session's running turn as the page follows it, in one place:
// whether a turn runs, its timing line (live_timing.js), the prompt-bubble
// flags of its merges, and the turn-end reads it waits on. forget() is the
// one reset (a session left, or its rendering started over).
import { createLiveTiming } from "./live_timing.js";

// +timingDeps+: createLiveTiming's.
export function createLiveTurn(timingDeps) {
  return {
    running: false,
    timing: createLiveTiming(timingDeps),
    // The last input_merged had an origin with no bubble: its merged text
    // (pending_input_merged) gets one ("report": a delegate report's).
    unmatchedMerge: false,
    // The running turn is one chi ran for delegate reports and its report
    // bubble isn't drawn yet: that bubble starts the turn.
    wakeStart: false,
    // The turn-end re-read (turn_completed): the final answer's rendered
    // markdown, the status and the timing. An answer_display re-read waits
    // for it.
    endRead: Promise.resolve(),
    // The wait of a turn_completed with display_pending for its
    // answer_display (turn_events.js displayWait). The worker may die in
    // between and never send one, so forget() releases it as well as its
    // own timeout: it must never hold the turn's answer forever.
    displayPending: null,
    // The last turn_failed's line, shown again after prompt_restored's resync.
    failedText: null,

    releaseDisplay() {
      this.displayPending?.finish();
      this.displayPending = null;
    },

    // Everything that belongs to one turn's following, but `running` (the
    // page's setTurnRunning redraws the composer with it).
    forget() {
      this.timing.drop();
      this.unmatchedMerge = false;
      this.wakeStart = false;
      this.releaseDisplay();
    },
  };
}
