// The stage's quiet signal (stage_view.js): a running turn that has sent no
// event for a while says so, since the dot blinks the same whether the
// model works or the line went dead (the Bridge's idle `: ping` never
// reaches EventSource's JS, and a running tool sends nothing between its
// start and end). The code says "stall" (stallOf, .ts-stall, data-stall);
// the user reads "quiet" (liveSlots' `quiet` and stage_model's QUIET_MS are
// other things). The rule is pure (stallOf, stallState); createStageStall
// draws it: a right-aligned span in the now row, its short text in the
// status row for a collapsed or plain stage, and the running call's clock.
// Its own module: new exports go in new modules (web-frontend.md).
import { clockText, genAge } from "./delivery_line.js";
import { node } from "./stage_slots.js";

// The levels' thresholds (ms) per kind: A, streamed or between steps; B,
// no first token yet in the step (a long prompt read, hidden reasoning).
export const STALL_MS = { A: [30000, 90000], B: [45000, 180000] };
// The stream down this long reads "reconnecting…" (a resync's own blink
// between workerGone and the new stream stays unsaid).
export const NET_MS = 1000;
// After the page shows again (visibilitychange): a background tab's
// stream may still be catching up.
export const GRACE_MS = 5000;
// The running call's clock shows from this far into it.
export const TOOL_CLOCK_MS = 10000;

const NONE = Object.freeze({ level: 0, long: "", short: "" });
const NET = Object.freeze({ level: "net", long: "reconnecting… · events paused", short: "reconnecting…" });

// The signal for a running turn: level 0 (nothing to say), 1, 2 or "net",
// and its texts (+long+ the stage's, +short+ a phone's and the status
// row's). A stream not live wins (no count: the events, not the model, are
// what paused); an explained silence says nothing: a running tool (its
// clock speaks), a blocking card, a timing note (a retry, plugins' setup),
// the end, the grace after a return.
export function stallOf({ kind = "A", silentMs = 0, toolRunning = false, blocked = false, note = "", streamLive = true, ended = false, graceUntil = 0, nowMs = 0 } = {}) {
  if (ended) return NONE;
  if (!streamLive) return NET;
  if (toolRunning || blocked || note || nowMs < graceUntil) return NONE;
  const b = kind === "B";
  const [l1, l2] = STALL_MS[b ? "B" : "A"];
  if (!(silentMs >= l1)) return NONE;
  const clock = clockText(silentMs / 1000);
  const short = b ? `thinking quietly ${clock}` : `quiet ${clock}`;
  return { level: silentMs >= l2 ? 2 : 1, long: `${short} · ${b ? "no tokens yet" : "no new events"}`, short };
}

// B while the step has had no token (no gen yet, or an open one with no
// text, thinking or call); else A (a closed step: between steps).
export function stallKind(gen) {
  if (!gen) return "B";
  return !gen.closed && !gen.text && !gen.thinking && !gen.tools?.length ? "B" : "A";
}

// The running call's clock ("0:12") from TOOL_CLOCK_MS on; "" before, or
// without a start (a replayed call the page didn't time).
export function toolClockText(startedAt, nowMs) {
  if (startedAt == null) return "";
  const ms = nowMs - startedAt;
  return ms >= TOOL_CLOCK_MS ? clockText(ms / 1000) : "";
}

// What a tick shows for +turn+ (turn_model.js's): the stall (stallOf) and
// the running call's clock (+toolClock+). +lastEventAt+: the page's clock
// at the turn's last event; +streamDownMs+: how long the stream hasn't been
// live (null: it is); +serverGen+: the snapshot's generation (a joiner's
// step clock, delivery_line.js genAge): before the first token a joiner
// counts from it, not from its own replay.
export function stallState({ turn, lastEventAt, nowMs, blocked = false, note = "", streamDownMs = null, ended = false, graceUntil = 0, serverGen = null }) {
  const gens = turn?.gens || [];
  const gen = gens[gens.length - 1];
  const running = gens.flatMap((g) => g.tools || []).reverse().find((row) => row.status === "running") || null;
  const kind = stallKind(gen);
  let silentMs = nowMs - lastEventAt;
  if (kind === "B") {
    const age = genAge(gen, serverGen, nowMs);
    if (age !== null) silentMs = Math.max(silentMs, age * 1000);
  }
  const streamLive = streamDownMs == null || streamDownMs < NET_MS;
  const stall = stallOf({ kind, silentMs, toolRunning: !!running, blocked, note, streamLive, ended, graceUntil, nowMs });
  return { ...stall, toolClock: running && !ended ? toolClockText(running.startedAt, nowMs) : "" };
}

// The drawer. +stage+: the stage's root (.stalled, data-stall: the hooks);
// +nowEl+: the now row (stage_slots.js drawNow rebuilds it: each draw puts
// its spans back when they were taken out); +timingSlot+: the status row's
// timing line, the head goes after it. A draw writes only when a text
// changes, so the 1 Hz tick under the threshold writes nothing.
export function createStageStall({ stage, nowEl, timingSlot }) {
  const stallEl = node("span", "ts-stall");
  const longEl = node("span", "long", stallEl);
  const shortEl = node("span", "short", stallEl);
  const clockEl = node("span", "ts-tool-clock");
  const head = node("span", "ts-stall-head");
  timingSlot.after(head);
  let shown = { key: null, clock: null, level: 0 };

  function drawLevel({ level, long, short }) {
    const key = `${level}|${long}`;
    if (shown.key === key) return;
    shown.key = key;
    shown.level = level;
    stage.classList.toggle("stalled", !!level);
    if (level) {
      stage.dataset.stall = String(level);
      nowEl.dataset.stall = String(level);
    } else {
      delete stage.dataset.stall;
      delete nowEl.dataset.stall;
    }
    longEl.textContent = long;
    shortEl.textContent = short;
    head.textContent = short;
  }

  function draw(state) {
    drawLevel(state);
    if (state.level && stallEl.parentNode !== nowEl) nowEl.appendChild(stallEl);
    else if (!state.level && stallEl.parentNode) stallEl.remove();
    const clock = state.toolClock || "";
    if (shown.clock !== clock) {
      shown.clock = clock;
      clockEl.textContent = clock;
    }
    if (clock && clockEl.parentNode !== nowEl) nowEl.insertBefore(clockEl, nowEl.querySelector(":scope > .task-stop"));
    else if (!clock && clockEl.parentNode) clockEl.remove();
  }

  function reset() {
    draw({ ...NONE, toolClock: "" });
    shown = { key: null, clock: null, level: 0 };
  }

  return { draw, reset, level: () => shown.level };
}
