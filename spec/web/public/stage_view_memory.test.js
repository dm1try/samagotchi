// What was opened of a running turn, per session, in memory
// (stage_view_memory.js): the capture, the put-back, the memory's rules.
import test from "node:test";
import assert from "node:assert/strict";
import { VIEW_MEMORY_CAP, applyView, captureView, createStageViewMemory } from "../../../lib/samagotchi/web/public/stage_view_memory.js";

// A stage stand-in: +open+ the cloud, +steps+ each step's open flag.
function fakeStage({ holds = true, open = false, steps = [] } = {}) {
  const els = steps.map((on) => {
    const el = { open: on };
    return { el, summary: { click: () => { el.open = !el.open; } } };
  });
  let cloudOpen = open;
  return {
    holds: () => holds,
    current: () => ({ turn: { gens: els.map(() => ({})) } }),
    cloud: { isOpen: () => cloudOpen, setCloud: (v) => { cloudOpen = v; } },
    step: (i) => els[i] || null,
    els,
    cloudOpen: () => cloudOpen,
  };
}
function fakeReader(item = null) {
  let open = item;
  return { isOpen: () => !!open, openItem: () => open, open: (it) => { open = it; }, item: () => open };
}

test("captureView: the cloud, its open steps and the reader's item; nothing opened or no turn: null", () => {
  const stage = fakeStage({ open: true, steps: [false, true, true] });
  const reader = fakeReader({ kind: "file", key: "/p/a.rb" });
  assert.deepEqual(captureView({ stage, turnId: "t1", reader }), { turnId: "t1", cloud: true, steps: [1, 2], reader: { kind: "file", key: "/p/a.rb" } });
  assert.deepEqual(captureView({ stage: fakeStage({ steps: [true] }), turnId: "t1", reader }), { turnId: "t1", cloud: false, steps: [], reader: { kind: "file", key: "/p/a.rb" } }, "a closed cloud keeps no steps");
  assert.ok(captureView({ stage: fakeStage({ steps: [true] }), turnId: "t1", reader: fakeReader() }) === null, "nothing opened");
  assert.ok(captureView({ stage, turnId: null, reader }) === null, "no running turn");
  assert.ok(captureView({ stage: fakeStage({ holds: false, open: true }), turnId: "t1" }) === null, "the stage holds none");
  assert.ok(captureView({ stage: { holds: () => true }, turnId: "t1" }) === null, "an older stage view: nothing");
});

test("applyView: the cloud opens, each saved step the replay drew closed opens, the reader opens its item", () => {
  const stage = fakeStage({ steps: [false, false, true] });
  const reader = fakeReader();
  applyView({ turnId: "t1", cloud: true, steps: [1, 2, 7], reader: { kind: "memory", key: "notes" } }, { stage, reader });
  assert.equal(stage.cloudOpen(), true);
  assert.deepEqual(stage.els.map((s) => s.el.open), [false, true, true], "an open one isn't toggled shut; a missing one is skipped");
  assert.deepEqual(reader.item(), { kind: "memory", key: "notes" });
  const idle = fakeStage({ holds: false });
  applyView({ turnId: "t1", cloud: true, steps: [], reader: null }, { stage: idle });
  assert.equal(idle.cloudOpen(), false, "no turn held: no cloud");
  applyView(null, { stage });
});

test("the memory: taken once and only for the same turn; leaving with nothing opened forgets; capped, the oldest first", () => {
  const memory = createStageViewMemory();
  const view = { turnId: "t1", cloud: true, steps: [], reader: null };
  memory.leave("a", view);
  assert.ok(memory.take("a", "t2") === null, "another turn");
  assert.ok(memory.take("a", "t1") === null, "dropped by the miss");
  memory.leave("a", view);
  assert.ok(memory.take("a", "t1") === view);
  assert.ok(memory.take("a", "t1") === null, "taken once");
  memory.leave("a", view);
  memory.leave("a", null);
  assert.equal(memory.size(), 0, "left with nothing opened");
  memory.leave("a", view);
  memory.drop("a");
  assert.equal(memory.size(), 0, "its turn ended");
  memory.leave(null, view);
  assert.equal(memory.size(), 0, "no session: nothing");
  for (let i = 0; i <= VIEW_MEMORY_CAP; i++) memory.leave(`s${i}`, { ...view, turnId: `t${i}` });
  assert.equal(memory.size(), VIEW_MEMORY_CAP);
  assert.ok(memory.take("s0", "t0") === null, "the oldest went");
  assert.ok(memory.take(`s${VIEW_MEMORY_CAP}`, `t${VIEW_MEMORY_CAP}`) !== null);
});
