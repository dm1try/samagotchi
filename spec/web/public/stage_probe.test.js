// The stage's perf probe (stage_probe.js): off, measured only runs its
// function; on (<body data-stage-probe="1">), it times it and report()
// gives each name's n/p50/p95/max once, the measures cleared after.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

const { measured, probing, report } = await import("../../../lib/samagotchi/web/public/stage_probe.js");

test("off: measured runs the function and records nothing; on: timed, reported once, exposed on the page", () => {
  delete document.body.dataset.stageProbe;
  performance.clearMeasures();
  assert.equal(probing(), false);
  assert.equal(measured("t:x", () => 7), 7);
  assert.deepEqual(report(), {});
  document.body.dataset.stageProbe = "1";
  try {
    assert.equal(probing(), true);
    for (let i = 0; i < 3; i += 1) measured("t:x", () => i);
    assert.equal(typeof globalThis.chiStageProbe.report, "function");
    const out = report();
    assert.equal(out["t:x"].n, 3);
    assert.ok(out["t:x"].p50 <= out["t:x"].p95 && out["t:x"].p95 <= out["t:x"].max);
    assert.deepEqual(report(), {}, "cleared after a report");
  } finally {
    delete document.body.dataset.stageProbe;
  }
});

test("probing: a measure that throws leaves the function's value; past 10k stage measures they are cleared", () => {
  document.body.dataset.stageProbe = "1";
  const was = performance.measure;
  try {
    performance.measure = () => { throw new Error("no room"); };
    assert.equal(measured("t:y", () => 5), 5);
    performance.measure = was;
    performance.clearMeasures();
    for (let i = 0; i < 10_050; i += 1) measured("t:z", () => i);
    assert.ok(performance.getEntriesByName("t:z").length <= 10_000, "capped");
  } finally {
    performance.measure = was;
    performance.clearMeasures();
    delete document.body.dataset.stageProbe;
  }
});
