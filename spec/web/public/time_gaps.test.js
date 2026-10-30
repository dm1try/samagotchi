import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createGapClock, groupGaps, groupTimes, lastActivity, timeGapEl } from "../../../lib/samagotchi/web/public/time_gaps.js";
import { normalizeTiming, turnGroups } from "../../../lib/samagotchi/web/public/timing.js";

// Local Date parts: the expectations hold in any time zone.
const localIso = (h, m, s = 0) => new Date(2026, 9, 24, h, m, s).toISOString();
const ms = (h, m, s = 0) => new Date(2026, 9, 24, h, m, s).getTime();
const NOW = ms(23, 0);

test("groupTimes: a turn from its first stamp to the later of its last stamp and its record's end", () => {
  const items = [
    { role: "user", content: "p", turn_id: "T1", at: localIso(9, 0) },
    { role: "assistant", content: "step", at: localIso(9, 1) },
    { role: "assistant", content: "done", at: localIso(9, 2) },
  ];
  const timing = normalizeTiming({ turn_records: [{ id: "T1", started_at: localIso(9, 0), duration_ms: 5 * 60_000 }] });
  const [group] = turnGroups(items, timing);
  assert.deepEqual(groupTimes(group, items), { start: ms(9, 0), end: ms(9, 5) });
});

test("groupTimes: an unstamped turn (saved before stamps) falls back to its record; a note to its own at; none: null", () => {
  const items = [{ role: "user", content: "old", turn_id: "T1" }, { role: "assistant", content: "a" },
    { role: "note", content: "n", label: "slack", at: localIso(10, 0) }, { role: "user", content: "no record" }];
  const timing = normalizeTiming({ turn_records: [{ id: "T1", started_at: localIso(8, 0), duration_ms: 60_000 }] });
  const groups = turnGroups(items, timing);
  assert.deepEqual(groups.map((g) => groupTimes(g, items)), [
    { start: ms(8, 0), end: ms(8, 1) }, { start: ms(10, 0), end: ms(10, 0) }, { start: null, end: null },
  ]);
});

test("groupGaps: a divider where 10+ quiet minutes passed between groups, none during work or across an unknown", () => {
  const items = [
    { role: "user", content: "one", at: localIso(9, 0) }, { role: "assistant", content: "a", at: localIso(9, 40) },
    // Right after a 40-minute turn: no gap (end to start).
    { role: "user", content: "two", at: localIso(9, 41) }, { role: "assistant", content: "b", at: localIso(9, 42) },
    { role: "note", content: "n", label: "slack", at: localIso(10, 30) },
    { role: "user", content: "unknown" }, { role: "assistant", content: "c" },
    { role: "user", content: "three", at: localIso(12, 0) },
  ];
  const groups = turnGroups(items, normalizeTiming({}));
  assert.deepEqual(groupGaps(groups, items, NOW), [null, null, "── 10:30 · 48 min later ──", null, null]);
  assert.equal(lastActivity(groups, items), ms(12, 0));
  assert.equal(lastActivity([], []), null);
});

test("groupTimes / groupGaps: a `!cmd`'s record is its own group (its index); saved with no time, the gap is measured across it", () => {
  const items = [
    { role: "user", content: "one", at: localIso(9, 0) }, { role: "assistant", content: "a", at: localIso(9, 1) },
    { role: "user", content: "!(ls)\nx" },
    { role: "user", content: "two", at: localIso(10, 0) },
  ];
  const groups = turnGroups(items, normalizeTiming({}));
  assert.deepEqual(groups.map((g) => g.kind), ["turn", "command", "turn"]);
  assert.deepEqual(groupTimes(groups[1], items), { start: null, end: null });
  const stamped = items.map((m, i) => (i === 2 ? { ...m, at: localIso(9, 30) } : m));
  assert.deepEqual(groupTimes(groups[1], stamped), { start: ms(9, 30), end: ms(9, 30) });
  assert.deepEqual(groupGaps(groups, items, NOW), [null, null, "── 10:00 · 59 min later ──"]);
});

test("createGapClock: a divider when activity starts after a quiet stretch; ends move the clock; no seed, none", () => {
  let now = ms(9, 0);
  const clock = createGapClock(() => now);
  assert.equal(clock.start(localIso(9, 0)), null);
  now = ms(9, 30);
  clock.end(null);
  assert.equal(clock.last, ms(9, 30));
  assert.equal(clock.start(localIso(9, 35)), null);
  assert.equal(clock.start(localIso(10, 20)), "── 10:20 · 45 min later ──");
  clock.seed(localIso(8, 0));
  now = ms(8, 20);
  // No time on the event: the page's clock.
  assert.equal(clock.start(null), "── 08:20 · 20 min later ──");
  clock.seed(null);
  assert.equal(clock.start(localIso(11, 0)), null);
});

test("the divider is its own element: a separator, never a bubble", () => {
  const el = timeGapEl("── 14:32 · 47 min later ──");
  assert.equal(el.className, "time-gap");
  assert.equal(el.getAttribute("role"), "separator");
  assert.equal(el.textContent, "── 14:32 · 47 min later ──");
});
