// P2's main pin (turn drawings): for each shared scenario
// (spec/shared/turn_drawings/*.json, written by the Ruby specs), the turn
// the live page draws (its events through the real stream handlers, the
// stage view, the bubbles and the cards' placement, then the hand-off)
// and the same turn after a reload (chi web's show for it, drawn by
// turnHistoryNodes from its drawing) read the same (history_shape.js), with
// no allow list.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection", "CSS"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} };
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const { turnHistoryNodes } = await import("../../../lib/samagotchi/web/public/turn_block.js");
const { compareShapes, historyShape } = await import("../../../lib/samagotchi/web/public/history_shape.js");
const { livePage } = await import("./live_page.js");

const DIR = new URL("../../shared/turn_drawings/", import.meta.url);
const scenarios = readdirSync(DIR).filter((f) => f.endsWith(".json")).sort()
  .map((f) => ({ name: f.replace(/\.json$/, ""), ...JSON.parse(readFileSync(new URL(f, DIR), "utf8")) }));

// The live turn's shape after its hand-off (+events+: the scenario's
// stream, the last turn's only when there are several).
async function liveShape(events) {
  const { historyEl, turnDom, handlers } = livePage();
  for (const event of events) await handlers[event.type]?.({ ...event });
  turnDom.handOff({ immediate: true });
  return historyShape(historyEl);
}

// The last turn's events, from the wake note announced just before it (a
// context wake's opening, which live drew as the note came in).
function lastTurnEvents(events) {
  const starts = events.map((e, i) => (e.type === "turn_started" ? i : -1)).filter((i) => i >= 0);
  const start = starts[starts.length - 1];
  return events.slice(events[start - 1]?.type === "context_added" ? start - 1 : start);
}

// The reloaded turn's shape: the show drawn, the drawn turn's pieces only.
function drawnShape(show) {
  document.body.innerHTML = '<div id="history"></div>';
  const historyEl = document.getElementById("history");
  historyEl.append(turnHistoryNodes(show.messages, {}, { thumbs: () => null, drawings: show.turn_drawings }));
  const ids = Object.keys(show.turn_drawings || {});
  const last = ids[ids.length - 1];
  return historyShape([...historyEl.children].filter((el) => el.dataset.drawn === last));
}

for (const scenario of scenarios) {
  test(`${scenario.name}: drawn after a reload as live drew it`, async () => {
    const live = await liveShape(lastTurnEvents(scenario.events));
    const reloaded = drawnShape(scenario.show);
    const verdict = compareShapes(live, reloaded);
    assert.ok(verdict.same, `${scenario.description}\nlive: ${JSON.stringify(live, null, 1)}\nreloaded: ${JSON.stringify(reloaded, null, 1)}`);
    assert.ok(reloaded.length > 0);
  });
}

// The synth arm (H3 step L): the same turn reloaded from a drawing chi web
// made from its messages (Bridge::TurnDrawings::Synth, the fixture's
// `synth`), against the live turn. What the synth can't have is
// Synth::LOSSES: the ones that change a shape are these, by their id there,
// and each scenario names the ones it has.
const SYNTH_LOSSES = {
  // A step that streamed only thinking and was asked again: its thinking
  // is saved nowhere, so its step (and a block of only such steps) is gone.
  empty_step_thinking: ([live, synth]) => synth === null && (live.kind === "block" || (live.kind === "step" && live.text === "thinking")),
};
const SYNTH_LOSSES_OF = { empty_retry: ["empty_step_thinking"] };

for (const scenario of scenarios) {
  test(`${scenario.name}: drawn from its messages after a reload as live drew it`, async () => {
    const live = await liveShape(lastTurnEvents(scenario.events));
    const reloaded = drawnShape(scenario.synth);
    const allowed = (SYNTH_LOSSES_OF[scenario.name] || []).map((id) => SYNTH_LOSSES[id]);
    const left = compareShapes(live, reloaded).differences.filter((pair) => !allowed.some((loss) => loss(pair)));
    assert.deepEqual(left, [], `${scenario.description}\nlive: ${JSON.stringify(live, null, 1)}\nsynth: ${JSON.stringify(reloaded, null, 1)}`);
    assert.ok(reloaded.length > 0);
  });
}

// A drawing chi web made up an id for (a turn saved before turn ids): its
// answer has no data-answer-turn (no Revise, no fold key for it), a live
// line's keeps its turn's.
test("a drawn answer is keyed by its end's own turn id only", () => {
  const plain = scenarios.find((s) => s.name === "plain_answer").show;
  const keyOf = (show) => {
    document.body.innerHTML = '<div id="history"></div>';
    const historyEl = document.getElementById("history");
    historyEl.append(turnHistoryNodes(show.messages, {}, { thumbs: () => null, drawings: show.turn_drawings }));
    return historyEl.querySelector(".bubble.output")?.getAttribute("data-answer-turn") ?? null;
  };
  assert.equal(keyOf(plain), "turn-plain");
  const made = JSON.parse(JSON.stringify(plain).replaceAll("turn-plain", "m1-0a1b2c3d"));
  delete made.turn_drawings["m1-0a1b2c3d"].end.turn_id;
  for (const item of made.messages) delete item.turn_id;
  assert.equal(keyOf(made), null);
});

test("every shared scenario has a show with its drawing", () => {
  assert.ok(scenarios.length >= 16);
  for (const s of scenarios) assert.ok(Object.keys(s.show?.turn_drawings || {}).length, s.name);
});
