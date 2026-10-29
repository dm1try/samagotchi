import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import {
  chipModel, chipTemplate, commandLine, createThinkingControl, formTemplate, LEVELS, nowText,
} from "../../../lib/samagotchi/web/public/thinking_chip.js";

// A template's markup (lit's marker comments dropped).
const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};

// The form's markup as the popover shows it (lit's marker comments dropped).
const formHtml = (summary, opts) => {
  const div = document.createElement("div");
  render(formTemplate(summary, opts), div);
  return htmlOf(div.firstElementChild);
};

const fromModel = { level: "off", source: "models: qwen", own: null };
const own = { level: "low", source: "session", own: "low" };
const bare = { level: "default", source: null, own: null };

test("the chip names the level, and the session when it set its own", () => {
  assert.equal(chipModel(fromModel).text, "think off");
  assert.equal(chipModel(fromModel).own, false);
  assert.equal(chipModel(fromModel).title, "Thinking: off (models: qwen). Click to change it for this session.");
  assert.equal(chipModel(own).text, "think low · session");
  assert.equal(chipModel(own).title, "Thinking: low (this session). Click to change it for this session.");
  const chip = markupOf(chipTemplate(own));
  assert.match(chip, /class="model think-chip own"/);
  assert.match(chip, /data-think-chip/);
});

test("the chip hides without a summary; the default with nothing set shows, as the place to set it", () => {
  assert.equal(chipModel(null), null);
  assert.equal(chipModel({}), null);
  assert.equal(markupOf(chipTemplate(null)), "");
  assert.equal(chipModel(bare).text, "think default");
  assert.equal(chipModel(bare).title, "Thinking: default (the model's own). Click to change it for this session.");
});

test("the form is the popover's markup as it was built as a string", () => {
  assert.equal(formHtml(own),
    '<form class="think-form llmctx-form"><div class="ctx-pop-head"><strong>Thinking</strong>' +
    '<span class="ctx-pop-kind">this session</span>' +
    '<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>' +
    '<div class="ctx-pop-meta think-now">Now: low (session)</div>' +
    '<label class="llmctx-field"><span>Level</span><span class="select-wrap"><select name="level">' +
    '<option value="default">follow the model</option><option value="off">off</option>' +
    '<option value="low" selected="">low</option><option value="medium">medium</option>' +
    '<option value="high">high</option></select></span></label>' +
    '<div class="ctx-pop-meta">From the next turn\'s start. On Gemma the whole prompt is read again; a hosted API reads the whole conversation again.</div>' +
    '<div class="ctx-pop-actions"><button type="submit" class="llmctx-set">Set</button></div></form>');
});

test("the form selects the session's own level, else follows the model, and names the level now", () => {
  const html = formHtml(fromModel);
  assert.match(html, /<option value="default" selected="">follow the model \(off\)<\/option>/);
  for (const level of LEVELS) assert.match(html, new RegExp(`<option value="${level}">${level}</option>`));
  assert.match(html, /Now: off \(models: qwen\)/);
  assert.match(html, /From the next turn's start/);
  assert.match(formHtml(own, { running: true }), /A turn is running: it applies after this turn/);
  assert.match(formHtml(own, { now: fromModel }), /Now: off \(models: qwen\)<\/div>.*<option value="low" selected="">/);
  assert.equal(nowText(bare), "Now: default (the model's own)");
});

// --yes: picking a level is the choice, and the form names the cost (no second ask).
test("a Set runs /thinking with the picked level and --yes, nothing when it is the one the form opened with", () => {
  assert.equal(commandLine("low", "default"), "/thinking low --yes");
  assert.equal(commandLine("default", "low"), "/thinking default --yes");
  assert.equal(commandLine("low", "low"), null);
  assert.equal(commandLine("high"), "/thinking high --yes");
});

// A control on the shim's document: the chip inside +el+, a stub
// window for the popover's place. shown() is the level the form opened
// with (the option marked selected): happy-dom 20 puts a select whose
// options lit inserted on its second option (a browser follows the
// attribute), so a spec reads the mark and sets the value it submits.
function control(opts) {
  const el = document.createElement("div");
  el.innerHTML = '<button data-think-chip>think</button>';
  document.body.append(el);
  const ran = [];
  const win = { innerWidth: 1000, innerHeight: 800 };
  const ctl = createThinkingControl({ el, run: (line) => ran.push(line), win, ...opts });
  const pop = document.getElementById(opts.id || "thinkingPopover");
  const chip = el.querySelector("[data-think-chip]");
  const submit = () => pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  const select = () => pop.querySelector("select");
  const shown = () => pop.querySelector("option[selected]").value;
  return { ctl, pop, chip, ran, submit, select, shown, done: () => { el.remove(); pop.remove(); } };
}

test("a click on the chip opens the form at the session's level; a Set runs /thinking, the same level nothing", () => {
  const c = control({ summary: () => own, session: () => "s1" });
  c.chip.click();
  assert.equal(c.ctl.open, true);
  assert.equal(c.shown(), "low");
  c.select().value = "high";
  c.submit();
  assert.deepEqual(c.ran, ["/thinking high --yes"]);
  assert.equal(c.ctl.open, false);
  assert.equal(c.pop.querySelector("form"), null);

  c.chip.click();
  c.select().value = "low";
  c.submit();
  assert.deepEqual(c.ran, ["/thinking high --yes"]);
  c.done();
});

test("an open form keeps the user's pick when the summary changes; only Now: follows; another session closes it", () => {
  let data = fromModel;
  let id = "s1";
  const c = control({ summary: () => data, session: () => id });
  c.chip.click();
  c.select().value = "medium";
  data = own;
  c.ctl.refresh();
  assert.equal(c.pop.querySelector(".think-now").textContent, "Now: low (session)");
  assert.equal(c.select().value, "medium");
  id = "s2";
  c.ctl.refresh();
  assert.equal(c.ctl.open, false);
  c.done();
});

test("a closed form forgets an unsent pick: the next open shows the level again", () => {
  const c = control({ summary: () => own, session: () => "s1" });
  c.chip.click();
  const first = c.select();
  first.value = "off";
  c.pop.querySelector("[data-act=close]").click();
  assert.equal(c.ctl.open, false);
  assert.equal(c.pop.querySelector("form"), null);
  c.chip.click();
  assert.notEqual(c.select(), first);
  assert.equal(c.shown(), "low");
  c.done();
});

