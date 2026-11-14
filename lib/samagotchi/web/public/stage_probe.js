// The stage's perf probe (script/stage-perf-probe, docs/testing.md): off
// unless the page was opened with ?stage_probe=1 (kept for the tab in
// sessionStorage, chi_stage_probe, so a reload or a hash jump keeps it;
// ?stage_probe=0 drops it) or <body data-stage-probe="1"> (read at each call:
// Web Inspector can set it after the page loaded). Probing, +measured+
// times its function as a performance measure, and the page gets
// globalThis.chiStageProbe.report(): each name's {n, p50, p95, max} in ms,
// the measures cleared after. Off, +measured+ only runs the function.
const KEY = "chi_stage_probe";
let kept = null;

// The tab's flag, read once per page load (storage can throw: off then).
function keptOn() {
  if (kept !== null) return kept;
  kept = false;
  try {
    const asked = new URLSearchParams(globalThis.location?.search || "").get("stage_probe");
    if (asked === "1") sessionStorage.setItem(KEY, "1");
    else if (asked === "0") sessionStorage.removeItem(KEY);
    kept = sessionStorage.getItem(KEY) === "1";
  } catch (_) {
    kept = false;
  }
  return kept;
}

export const probing = () => globalThis.document?.body?.dataset?.stageProbe === "1" || keptOn();

const at = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
const round = (ms) => Math.round(ms * 1000) / 1000;

// Each name's measures since the last report or clear: past MAX_MEASURES the
// name's measures are cleared (a page left probing for hours stays small).
const MAX_MEASURES = 10_000;
const counts = new Map();

export function report() {
  counts.clear();
  const byName = {};
  for (const m of performance.getEntriesByType("measure")) (byName[m.name] ||= []).push(m.duration);
  performance.clearMeasures();
  performance.clearMarks();
  return Object.fromEntries(Object.entries(byName).map(([name, list]) => {
    const sorted = list.sort((a, b) => a - b);
    return [name, { n: sorted.length, p50: round(at(sorted, 0.5)), p95: round(at(sorted, 0.95)), max: round(sorted[sorted.length - 1]) }];
  }));
}

export function measured(name, fn) {
  if (!probing()) return fn();
  globalThis.chiStageProbe ||= { report };
  const start = performance.now();
  try {
    return fn();
  } finally {
    // The probe never breaks the page: a measure the browser refuses is lost.
    try {
      const n = (counts.get(name) || 0) + 1;
      if (n > MAX_MEASURES) performance.clearMeasures(name);
      counts.set(name, n > MAX_MEASURES ? 1 : n);
      performance.measure(name, { start, end: performance.now() });
    } catch (_) { /* not measured */ }
  }
}
