import { canon, htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { chainLinkTemplate, CLOCK_NONE, infoBarHtml, memoriesTooltip, NEXT, PREV, renderInfoBar } from "../../../lib/samagotchi/web/public/info_bar.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";

const ID = "0123456789abcdef";

// A bar with only what every open session has.
const bare = {
  id: ID, status: "idle", model: { text: "qwen", title: "qwen", mismatch: false },
  chain: { prev: null, next: null }, parent: null, kids: null, settings: null, toolkit: null, notes: null,
  memories: [], dir: "/p", ctx: { text: "ctx ?", tip: "no request yet" }, speed: null, clock: "", worker: null,
};

const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};

// No relations: the setup and the telemetry, one hairline between them.
test("infoBarHtml: a bare session's line, as the string builder wrote it", () => {
  assert.equal(markupOf(infoBarHtml(bare)), canon(
    `<div class="meta"><span class="bar-group setup"><button type="button" class="id" title="Session id ${ID}: click to copy it">01234567</button>` +
    `<span class="status idle"><span>idle</span></span><span class="model" title="qwen">qwen</span></span>` +
    `<span class="bar-sep" aria-hidden="true"></span><span class="bar-group telemetry">` +
    `<span class="dir" title="/p"><bdi>/p</bdi></span><span class="model ctx" title="no request yet">ctx ?</span>` +
    `<span class="model session-time empty" title="This session's time: no turn yet">–</span></span></div>`,
  ));
});

// The chips a turn rewrites keep their place: the clock and the speed show
// before their first number (muted placeholders), so neither joins the line
// mid-turn; the same nodes then take the numbers.
test("infoBarHtml: the clock and the speed show as placeholders before their numbers, in the same nodes", () => {
  const el = document.createElement("div");
  renderInfoBar(el, { ...bare, speed: { text: "– tok/s", tip: "none yet", empty: true } });
  const speed = el.querySelector(".speed");
  const clock = el.querySelector(".session-time");
  assert.equal(speed.className, "model speed empty");
  assert.equal(clock.className, "model session-time empty");
  assert.equal(clock.textContent, CLOCK_NONE);
  renderInfoBar(el, { ...bare, speed: { text: "42 tok/s", tip: "last", empty: false }, clock: "9.5s" });
  assert.equal(el.querySelector(".speed"), speed);
  assert.equal(el.querySelector(".session-time"), clock);
  assert.equal(speed.className, "model speed");
  assert.equal(clock.className, "model session-time");
  assert.equal(`${speed.textContent} ${clock.textContent}`, "42 tok/s 9.5s");
});

test("infoBarHtml: every part, in the bar's order", () => {
  const full = {
    ...bare, status: "running", model: { text: "qwen", title: "served other", mismatch: true },
    chain: { prev: { id: "aaaaaaaa1", date: "10-09", stamp: "2026-10-09 14:32", preview: "first", archived: true }, next: { id: "bbbbbbbb2", date: "", preview: "" } },
    parent: { id: "pppppppp9", title: "Delegated by pppppppp" },
    kids: { text: "2 delegates", title: "2 delegates", waitingText: "1 waiting" },
    settings: {
      llmContext: { strategy: "stale", strategy_source: "session", strategy_where: "the session", apply: "payoff",
                    apply_where: "llm_context.apply", budget_where: "llm_context.budget_tokens", own: { strategy: ["stale"] } },
      thinking: { level: "low", source: "session", own: "low" },
      reasoningHistory: { level: "all", source: "session", own: "all" },
    },
    toolkit: { summary: { name: "lean", label: "lean", left_out: ["delegate"] }, defaultKit: "full" },
    notes: { text: "notes 1", title: "deepseek" },
    memories: ["a", "b"],
    speed: { text: "30 t/s", tip: "Decode speed of the last generation" },
    clock: "5s",
    worker: { badge: { text: "chi 0.53", title: "older", restart: true }, busy: true },
  };
  const div = document.createElement("div");
  render(infoBarHtml(full), div);
  const parts = [...div.querySelector(".meta").children].map((el) => [el.className, [...el.children].map((kid) => kid.className)]);
  assert.deepEqual(parts, [
    ["bar-group setup", ["id", "status running", "model served-mismatch", "model settings-chip own", "model tools-chip", "model notes-chip", "model mem-chip"]],
    ["bar-sep", []],
    ["bar-group relations", ["model chain-link", "model chain-link", "model parent", "model children-chip waiting"]],
    ["bar-sep", []],
    ["bar-group telemetry", ["dir", "model ctx", "model speed", "model session-time", "worker-badge"]],
  ]);
  assert.equal(div.querySelector(".id").textContent, "01234567");
  const [prev, next] = div.querySelectorAll(".chain-link");
  assert.equal(prev.textContent, "← 10-09");
  assert.equal(prev.title, "The previous link of this chain: aaaaaaaa · 2026-10-09 14:32 · first (archived)");
  assert.equal(prev.getAttribute("href"), "#/s/aaaaaaaa1");
  assert.equal(next.textContent, "bbbbbbbb →");
  // The parent: an up arrow and its short id; the title says "delegated by".
  assert.equal(div.querySelector(".parent").textContent, "↑ pppppppp");
  assert.equal(div.querySelector(".parent").title, "Delegated by pppppppp");
  assert.equal(div.querySelector(".children-chip").textContent, "2 delegates · 1 waiting");
  assert.equal(div.querySelector(".children-chip").title, "2 delegates (all sessions)");
  const gear = div.querySelector(".settings-chip");
  assert.ok(gear.hasAttribute("data-settings-chip"));
  assert.equal(gear.textContent, "⚙ think low · reasoning all · ctx stale");
  assert.match(gear.title, /^Thinking: low \(this session\)\. Reasoning history: all \(this session\)\. LLM context: stale \(the session\)/);
  assert.equal(div.querySelector(".mem-chip").textContent, "mem 2");
  assert.equal(div.querySelector(".session-time").textContent, "5s");
  const restart = div.querySelector(".worker-restart");
  assert.equal(restart.textContent, "restarting…");
  assert.equal(restart.disabled, true);
});

test("renderInfoBar: a clock tick rewrites the clock's text alone; the bar's nodes stay", () => {
  const el = document.createElement("div");
  renderInfoBar(el, { ...bare, clock: "1s" });
  const id = el.querySelector(".id");
  const clock = el.querySelector(".session-time");
  renderInfoBar(el, { ...bare, clock: "2s" });
  assert.equal(el.querySelector(".id"), id);
  assert.equal(el.querySelector(".session-time"), clock);
  assert.equal(clock.textContent, "2s");
});

// The relations come and go (a participant invited, a chain's next link)
// without a redraw of the other groups: the clock keeps its node.
test("renderInfoBar: the relations group (and its hairline) only with a relation; the other groups keep their nodes", () => {
  const el = document.createElement("div");
  renderInfoBar(el, bare);
  assert.equal(el.querySelector(".relations"), null);
  assert.equal(el.querySelectorAll(".bar-sep").length, 1);
  const clock = el.querySelector(".session-time");
  renderInfoBar(el, { ...bare, participants: { text: "participants · invite", count: 0, present: false, title: "Invite" } });
  assert.equal(el.querySelector(".relations .participants-chip").textContent, "participants · invite");
  assert.equal(el.querySelectorAll(".bar-sep").length, 2);
  assert.ok(el.querySelector(".session-time") === clock);
});

test("renderInfoBar: the memories in the tooltip; no session, no bar", () => {
  const el = document.createElement("div");
  renderInfoBar(el, { ...bare, memories: ["a"], preloaded: ["b"] });
  assert.equal(el.title, "memories: a · preloaded: b");
  renderInfoBar(el, null);
  assert.equal(el.title, "");
  assert.equal(el.querySelector(".meta"), null);
});

test("memoriesTooltip: the used memories always, preloaded and muted when there are any", () => {
  assert.equal(memoriesTooltip([], [], []), "memories: —");
  assert.equal(memoriesTooltip(["a", "b"], null, ["c"]), "memories: a, b · muted: c");
});

test("chainLinkTemplate: the short id when the link has no date", () => {
  assert.equal(markupOf(chainLinkTemplate({ id: "cccccccc3" }, PREV, "Prev")),
               canon('<a class="model chain-link" href="#/s/cccccccc3" title="Prev: cccccccc">← cccccccc</a>'));
  assert.match(markupOf(chainLinkTemplate({ id: "cccccccc3", date: "10-10" }, NEXT, "Next")), />10-10 →</);
});

test("infoBarHtml: the 🧰 chip follows the bar's own toolkit, so a switch to a full session shows 🧰 alone", () => {
  const div = document.createElement("div");
  render(infoBarHtml({ ...bare, toolkit: { summary: { name: "lean", label: "lean +delegate" }, defaultKit: "full" } }), div);
  assert.equal(div.querySelector(".tools-chip").textContent, "🧰 lean +delegate");
  // Another session opened (app.js resets its state to emptySessionState: toolkit null).
  const reset = emptySessionState();
  render(infoBarHtml({ ...bare, id: "fedcba9876543210", toolkit: { summary: reset.toolkit, defaultKit: reset.toolkitDefault } }), div);
  assert.equal(div.querySelector(".tools-chip").textContent, "🧰");
  assert.match(div.querySelector(".tools-chip").title, /^Toolkit: full \(the default\), every tool is declared\./);
});

test("infoBarHtml: the ⚙ chip reads ⚙ alone while the session follows the model; no summaries, no chip", () => {
  const div = document.createElement("div");
  const follows = { thinking: { level: "high", source: "models: qwen", own: null }, reasoningHistory: null, llmContext: null };
  render(infoBarHtml({ ...bare, settings: follows }), div);
  const gear = div.querySelector(".settings-chip");
  assert.equal(gear.className, "model settings-chip");
  assert.equal(gear.textContent, "⚙");
  assert.equal(gear.getAttribute("aria-label"), "Session settings");
  assert.equal(gear.previousElementSibling.className, "model");
  render(infoBarHtml({ ...bare, settings: { thinking: null, reasoningHistory: null, llmContext: null } }), div);
  assert.equal(div.querySelector(".settings-chip"), null);
});
