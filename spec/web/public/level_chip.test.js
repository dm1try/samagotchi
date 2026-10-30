import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { chipModel, commandLine, createLevelControl, formTemplate, segments } from "../../../lib/samagotchi/web/public/level_chip.js";

// A setting of its own: the factory knows nothing of thinking.
const cfg = {
  name: "Colour", prefix: "col", command: "/colour", levels: ["red", "blue"], anchor: "[data-col-chip]",
  formClass: "col-form", popoverClass: "col-popover", nowClass: "col-now", when: () => "Soon.",
};

const formHtml = (summary, opts) => {
  const div = document.createElement("div");
  render(formTemplate(cfg, summary, opts), div);
  return htmlOf(div.firstElementChild);
};

test("a config's chip names its word, level and the session's own", () => {
  assert.deepEqual(chipModel(cfg, { level: "red", source: "session", own: "red" }),
    { text: "col red · session", title: "Colour: red (this session). Click to change it for this session.", own: true });
  assert.equal(chipModel(cfg, { level: "blue", source: "models: m", own: null }).title,
    "Colour: blue (models: m). Click to change it for this session.");
  assert.equal(chipModel(cfg, null), null);
});

test("a config's form lists its levels after follow the model, with its classes and note", () => {
  const html = formHtml({ level: "blue", source: null, own: null });
  assert.match(html, /^<form class="col-form llmctx-form">/);
  assert.match(html, /<strong>Colour<\/strong>/);
  assert.match(html, /<div class="ctx-pop-meta col-now">Now: blue \(the model's own\)<\/div>/);
  assert.match(html, /<option value="default" selected="">follow the model \(blue\)<\/option><option value="red">red<\/option><option value="blue">blue<\/option>/);
  assert.match(html, /<div class="ctx-pop-meta">Soon\.<\/div>/);
});

test("a config's segments: follow the model first (its level in brackets), then its levels; the choice pressed", () => {
  const labels = (segs) => segs.map((s) => `${s.label}${s.pressed ? "*" : ""}`);
  assert.deepEqual(labels(segments(cfg, { level: "blue" }, null)), ["default (blue)*", "red", "blue"]);
  assert.deepEqual(labels(segments(cfg, { level: "blue" }, "red")), ["default (blue)", "red*", "blue"]);
  assert.deepEqual(segments(cfg, { level: "blue" }, null)[0], { value: "default", label: "default (blue)", title: "Follow the model (blue)", pressed: true });
  assert.equal(segments(cfg, { level: "default" }, null)[0].label, "default");
  assert.equal(segments(cfg, null, "red"), null);
});

test("a Set's line is the config's command with --yes", () => {
  assert.equal(commandLine(cfg, "red", "default"), "/colour red --yes");
  assert.equal(commandLine(cfg, "red", "red"), null);
});

test("the control opens on the config's anchor, in its popover, and runs its line", () => {
  const el = document.createElement("div");
  el.innerHTML = "<button data-col-chip>col</button><button data-other>x</button>";
  document.body.append(el);
  const ran = [];
  const ctl = createLevelControl({ cfg, el, id: "colPopover", summary: () => ({ level: "red", source: "session", own: "red" }),
                                   session: () => "s1", run: (line) => ran.push(line), win: { innerWidth: 1000, innerHeight: 800 } });
  const pop = document.getElementById("colPopover");
  assert.equal(pop.className, "ctx-popover col-popover");
  el.querySelector("[data-other]").click();
  assert.equal(ctl.open, false);
  el.querySelector("[data-col-chip]").click();
  assert.equal(ctl.open, true);
  pop.querySelector("select").value = "blue";
  pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  assert.deepEqual(ran, ["/colour blue --yes"]);
  el.remove();
  pop.remove();
});
