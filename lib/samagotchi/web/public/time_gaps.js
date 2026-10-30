// The history's gap dividers: one dim line ("── 14:32 · 47 min later ──",
// format.js gapText) where a quiet stretch of GAP_SECONDS or more passed
// between the end of one activity and the start of the next (a turn, a
// note, a reminder). Nothing during active work: a long turn followed at
// once by another has none (measured end to start).
//
// The times: a history entry's `at` (MessageTime, the server forwards it),
// else for a turn its record's started_at and started_at + duration_ms
// (sessions saved before stamps). Live: the events' at / created_at, else
// the page's clock (createGapClock).
//
// The divider is its own element (.time-gap), never a .bubble or a
// .turn-work: code that walks those (turn prompts, recap placement, the
// stage's hand-off) never sees it.
import { html } from "./vendor/lit-html.js";
import { elementOf } from "./turn_html.js";
import { gapText, timeOf } from "./format.js";

export const TIME_GAP_CLASS = "time-gap";

export function timeGapTemplate(text) {
  return html`<div class=${TIME_GAP_CLASS} role="separator">${text}</div>`;
}

export function timeGapEl(text) {
  return elementOf(timeGapTemplate(text));
}

// The history items a group (timing.js turnGroups) holds, by index.
function groupIndexes(group) {
  if (group.kind === "note" || group.kind === "steer" || group.kind === "command") return [group.i];
  if (group.kind === "answer") return [group.answer];
  const steps = group.steps || [];
  return [
    group.user, ...steps.map((step) => step.i), ...steps.flatMap((step) => step.steers || []),
    ...(group.steers || []), ...(group.merged || []), group.answer, group.emptyAnswer,
  ].filter((i) => Number.isInteger(i));
}

// A group's start and end (epoch ms, null when unknown): its first stamped
// entry's time, else its turn record's start; its last activity: the later
// of its last stamped entry and its record's end (a turn's tool calls and
// hooks run after its last message).
export function groupTimes(group, items) {
  const stamps = groupIndexes(group).map((i) => timeOf(items[i]?.at)?.getTime()).filter(Number.isFinite);
  const record = group.record || null;
  const recordStart = timeOf(record?.started_at)?.getTime();
  const duration = Number(record?.duration_ms);
  const recordEnd = Number.isFinite(recordStart) && Number.isFinite(duration) ? recordStart + duration : NaN;
  const start = stamps.length ? Math.min(...stamps) : Number.isFinite(recordStart) ? recordStart : null;
  const ends = [...stamps, recordEnd].filter(Number.isFinite);
  return { start, end: ends.length ? Math.max(...ends) : start };
}

// For each group, the divider text before it, or null. A group with no
// known time draws none and hides the gap across it (no divider measured
// over a stretch whose times are unknown). A `!cmd`'s record is saved with
// no time: it draws none and the gap is measured across it (it ran in that
// stretch).
export function groupGaps(groups, items, now = Date.now()) {
  let prevEnd = null;
  return groups.map((group) => {
    const { start, end } = groupTimes(group, items);
    if (group.kind === "command" && start === null) return null;
    const text = prevEnd !== null && start !== null ? gapText(prevEnd, start, now) : null;
    prevEnd = end;
    return text;
  });
}

// The last activity the history shows (epoch ms), or null: the live
// dividers' starting point.
export function lastActivity(groups, items) {
  for (let k = groups.length - 1; k >= 0; k -= 1) {
    const { end } = groupTimes(groups[k], items);
    if (end !== null) return end;
  }
  return null;
}

// The live page's last activity: seeded from the drawn history, moved at
// every start and end of activity. +now+: the page's clock (epoch ms).
export function createGapClock(now = () => Date.now()) {
  let last = null;
  const at = (time) => timeOf(time)?.getTime() ?? now();
  return {
    // The history was drawn (a render, a resync): its last activity.
    seed(time) { last = timeOf(time)?.getTime() ?? null; },
    // Activity starts at +time+ (an event's at; none: now): the divider's
    // text when a gap passed since the last, else null.
    start(time) {
      const t = at(time);
      const text = last === null ? null : gapText(last, t, now());
      last = Math.max(last ?? t, t);
      return text;
    },
    // Activity ended (a turn's end): the next gap counts from here.
    end(time) { last = at(time); },
    get last() { return last; },
  };
}
