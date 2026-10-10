import test from "node:test";
import assert from "node:assert/strict";
import {
  chipHtml, chipModel, commandLine, formHtml, LEVELS, nowText, withChoice,
} from "../../../lib/samagotchi/web/public/thinking_chip.js";
import { NEW_CHAT } from "../../../lib/samagotchi/web/public/llm_context_chip.js";

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

const fromModel = { level: "off", source: "models: qwen", own: null };
const own = { level: "low", source: "session", own: "low" };
const bare = { level: "default", source: null, own: null };

test("the chip names the level, and the session when it set its own", () => {
  assert.equal(chipModel(fromModel).text, "think off");
  assert.equal(chipModel(fromModel).own, false);
  assert.equal(chipModel(fromModel).title, "Thinking: off (models: qwen). Click to change it for this session.");
  assert.equal(chipModel(own).text, "think low · session");
  assert.equal(chipModel(own).title, "Thinking: low (this session). Click to change it for this session.");
  assert.match(chipHtml(own, esc), /class="model think-chip own"[^>]*data-think-chip/);
});

test("the chip hides without a summary; the default with nothing set shows, as the place to set it", () => {
  assert.equal(chipModel(null), null);
  assert.equal(chipModel({}), null);
  assert.equal(chipHtml(null, esc), "");
  assert.equal(chipModel(bare).text, "think default");
  assert.equal(chipModel(bare).title, "Thinking: default (the model's own). Click to change it for this session.");
});

test("the new chat's choice lays over the model's level, and shows even over a bare default", () => {
  assert.equal(withChoice(fromModel, null), fromModel);
  assert.equal(chipModel(withChoice(bare, "high"), { kind: NEW_CHAT }).text, "think high · new chat");
  assert.match(chipModel(withChoice(fromModel, "low"), { kind: NEW_CHAT }).title, /low \(the new chat\)\. Click to change it for the new chat/);
  assert.equal(chipModel(fromModel, { kind: NEW_CHAT }).text, "think off");
});

test("the form selects the session's own level, else follows the model, and names the level now", () => {
  const html = formHtml(fromModel, esc);
  assert.match(html, /<option value="default" selected>follow the model \(off\)<\/option>/);
  for (const level of LEVELS) assert.match(html, new RegExp(`<option value="${level}">${level}</option>`));
  assert.match(html, /Now: off \(models: qwen\)/);
  assert.match(html, /From the next turn's start/);
  assert.match(formHtml(own, esc), /<option value="low" selected>low<\/option>/);
  assert.match(formHtml(own, esc, { running: true }), /A turn is running: it applies after this turn/);
  assert.equal(nowText(bare), "Now: default (the model's own)");

  const fresh = formHtml(fromModel, esc, { kind: NEW_CHAT, choice: "high" });
  assert.match(fresh, /<option value="high" selected>/);
  assert.match(fresh, /not remembered for the next one/);
});

test("a Set runs /thinking with the picked level, nothing when it is the one the form opened with", () => {
  assert.equal(commandLine("low", "default"), "/thinking low");
  assert.equal(commandLine("default", "low"), "/thinking default");
  assert.equal(commandLine("low", "low"), null);
  assert.equal(commandLine("high"), "/thinking high");
});
