import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import {
  chipModel, chipTemplate, commandLine, createReasoningHistoryControl, formTemplate,
} from "../../../lib/samagotchi/web/public/reasoning_history_chip.js";
import { chipTemplate as thinkingChip } from "../../../lib/samagotchi/web/public/thinking_chip.js";

const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};

const own = { level: "all", source: "session", own: "all" };
const fromHost = { level: "drop", source: "hosts.splash", own: null };

test("the chip reads reasoning and the level, the session's own marked", () => {
  assert.equal(chipModel(own).text, "reasoning all · session");
  assert.equal(chipModel(fromHost).text, "reasoning drop");
  assert.equal(chipModel(fromHost).title, "Reasoning history: drop (hosts.splash). Click to change it for this session.");
  const chip = markupOf(chipTemplate(own));
  assert.match(chip, /class="model rh-chip own"/);
  assert.match(chip, /data-rh-chip/);
  assert.doesNotMatch(chip, /data-think-chip/);
});

test("the chip hides without a summary: a native host, or an older worker", () => {
  assert.equal(chipModel(null), null);
  assert.equal(markupOf(chipTemplate(null)), "");
});

test("the form offers drop, turn and all, and says a change to or from all re-reads the conversation", () => {
  const div = document.createElement("div");
  render(formTemplate(fromHost), div);
  const html = htmlOf(div.firstElementChild);
  assert.match(html, /<strong>Reasoning history<\/strong>/);
  assert.match(html, /<option value="drop">drop<\/option><option value="turn">turn<\/option><option value="all">all<\/option>/);
  assert.match(html, /A change to or from all makes the server read the conversation again/);
  assert.equal(commandLine("all", "default"), "/reasoning-history all --yes");
});

test("its chip's clicks open its own popover, not the thinking chip's", () => {
  const el = document.createElement("div");
  render([thinkingChip({ level: "low", source: null, own: null }), chipTemplate(own)], el);
  document.body.append(el);
  const ran = [];
  const ctl = createReasoningHistoryControl({ el, summary: () => own, session: () => "s1", run: (line) => ran.push(line),
                                              win: { innerWidth: 1000, innerHeight: 800 } });
  el.querySelector("[data-think-chip]").click();
  assert.equal(ctl.open, false);
  el.querySelector("[data-rh-chip]").click();
  assert.equal(ctl.open, true);
  const pop = document.getElementById("reasoningHistoryPopover");
  pop.querySelector("select").value = "drop";
  pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  assert.deepEqual(ran, ["/reasoning-history drop --yes"]);
  el.remove();
  pop.remove();
});
