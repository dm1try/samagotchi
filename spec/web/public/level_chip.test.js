import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { commandLine, followSegment, segments } from "../../../lib/samagotchi/web/public/level_chip.js";
import { commandLine as thinkingLine, LEVELS as THINKING_LEVELS } from "../../../lib/samagotchi/web/public/thinking_chip.js";
import { commandLine as reasoningLine, LEVELS as REASONING_LEVELS } from "../../../lib/samagotchi/web/public/reasoning_history_chip.js";

// A setting of its own: the builders know nothing of thinking.
const cfg = { name: "Colour", prefix: "col", command: "/colour", levels: ["red", "blue"], cost: "Soon." };
const labels = (segs) => segs.map((s) => `${s.label}${s.pressed ? "*" : ""}`);

test("a config's segments: follow the model first (its level in brackets), then its levels; the choice pressed", () => {
  assert.deepEqual(labels(segments(cfg, { level: "blue" }, null)), ["default (blue)*", "red", "blue"]);
  assert.deepEqual(labels(segments(cfg, { level: "blue" }, "red")), ["default (blue)", "red*", "blue"]);
  assert.deepEqual(segments(cfg, { level: "blue" }, null)[0], { value: "default", label: "default (blue)", title: "Follow the model (blue)", pressed: true });
  assert.equal(segments(cfg, { level: "default" }, null)[0].label, "default");
  assert.equal(segments(cfg, null, "red"), null);
});

// A session with its own level: the summary's level is the session's, not
// the model's, so the default segment doesn't name it as the model's.
test("a session's own level: the default segment reads default alone, the own level pressed", () => {
  const own = { level: "red", source: "session", own: "red" };
  assert.deepEqual(labels(segments(cfg, own, own.own)), ["default", "red*", "blue"]);
  assert.deepEqual(followSegment("red", true), { value: "default", label: "default", title: "Follow the model" });
  // The start page's summary (GET /api/models) has no own: the model's value shows.
  assert.deepEqual(labels(segments(cfg, { level: "red", source: "models: m", own: null }, null)), ["default (red)*", "red", "blue"]);
});

// --yes: a pick is the choice, and the panel names the cost (no second ask).
test("a pick's line is the config's command with --yes; the level the session has is nothing", () => {
  assert.equal(commandLine(cfg, "red", "default"), "/colour red --yes");
  assert.equal(commandLine(cfg, "red", "red"), null);
  assert.equal(commandLine(cfg, "blue"), "/colour blue --yes");
  assert.equal(thinkingLine("low", "default"), "/thinking low --yes");
  assert.equal(thinkingLine("default", "low"), "/thinking default --yes");
  assert.equal(thinkingLine("low", "low"), null);
  assert.equal(reasoningLine("all", "default"), "/reasoning-history all --yes");
  assert.deepEqual(THINKING_LEVELS, ["off", "low", "medium", "high"]);
  assert.deepEqual(REASONING_LEVELS, ["drop", "turn", "all"]);
});
