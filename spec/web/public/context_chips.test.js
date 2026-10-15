import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  addFormTemplate, ageText, chipModel, chipsTemplate, createContextChips, hintUrl, popoverTemplate,
} from "../../../lib/samagotchi/web/public/context_chips.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

// A template drawn into a fresh element, and its markup (lit's marker
// comments dropped).
const drawn = (template) => {
  const div = document.createElement("div");
  render(template, div);
  return div;
};
const markupOf = (template) => htmlOf(drawn(template));
// The same node (assert.equal's message would inspect a whole DOM node).
const same = (actual, expected, what) => assert.ok(actual === expected, `${what}: not the same node`);

const NOW = Date.parse("2026-10-05T12:00:00Z");
const ago = (s) => new Date(NOW - s * 1000).toISOString();
const row = (over = {}) => ({ name: "pr-1", scope: "session", kind: "cmd", every_seconds: 300, why: "the PR",
  hint: "https://github.com/x/y/pull/1", summary: "2 new comments", error: null, fetched_at: ago(180),
  has_text: true, unread: false, muted: false, ...over });

test("ageText: now, minutes, hours, days; blank for none", () => {
  assert.equal(ageText(ago(20), NOW), "now");
  assert.equal(ageText(ago(180), NOW), "3m");
  assert.equal(ageText(ago(7300), NOW), "2h");
  assert.equal(ageText(ago(3 * 86400), NOW), "3d");
  assert.equal(ageText(null, NOW), "");
});

test("hintUrl: only http(s) links", () => {
  assert.equal(hintUrl(" https://x/1 "), "https://x/1");
  assert.equal(hintUrl("javascript:alert(1)"), null);
  assert.equal(hintUrl("branch main"), null);
});

test("chipModel: name · age, the state by error, text and unread; muted ones left out", () => {
  const chips = chipModel([row({ unread: true }), row({ name: "ci", error: "exit 1" }), row({ name: "n", has_text: false, fetched_at: null }),
                           row({ name: "q", muted: true }), row({ name: "ok" })], NOW);
  assert.deepEqual(chips.map((c) => [c.label, c.state]), [["pr-1 · 3m", "unread"], ["ci · 3m", "error"], ["n", "empty"], ["ok · 3m", "ok"]]);
  assert.equal(chips[0].title, "2 new comments · changed; the agent hasn't read it yet");
  assert.equal(chips[1].title, "2 new comments · last refresh failed: exit 1");
});

test("chipsTemplate: a dot only for an unread change, names as text", () => {
  const el = drawn(chipsTemplate(chipModel([row({ unread: true }), row({ name: "<x>" })], NOW)));
  const chips = [...el.querySelectorAll(".ctx-chip")];
  assert.deepEqual(chips.map((c) => [c.className, c.dataset.name, c.textContent]),
                   [["ctx-chip unread", "pr-1", "pr-1 · 3m"], ["ctx-chip ok", "<x>", "<x> · 3m"]]);
  assert.equal(chips[0].firstElementChild.className, "ctx-dot");
  assert.equal(el.querySelectorAll(".ctx-dot").length, 1);
  assert.equal(chips[0].getAttribute("aria-haspopup"), "dialog");
  assert.equal(chips[0].title, "2 new comments · changed; the agent hasn't read it yet");
  assert.match(markupOf(chipsTemplate(chipModel([row()], NOW), { open: "pr-1" })), /class="ctx-chip ok open"/);
});

test("popoverTemplate: why, a link for a URL hint, summary, age, error; detach or mute by scope", () => {
  const el = drawn(popoverTemplate(row({ unread: true, error: "exit 1: boom" }), { now: NOW }));
  const text = (sel) => el.querySelector(sel)?.textContent;
  assert.equal(text("strong"), "pr-1");
  assert.equal(text(".ctx-pop-kind"), "session · runs every 300s");
  const link = el.querySelector("a.ctx-pop-hint");
  assert.deepEqual([link.getAttribute("href"), link.target, link.rel, link.textContent],
                   ["https://github.com/x/y/pull/1", "_blank", "noopener noreferrer", "https://github.com/x/y/pull/1"]);
  assert.equal(text(".ctx-pop-why"), "the PR");
  assert.equal(text(".ctx-pop-summary"), "2 new comments");
  assert.equal(text(".ctx-pop-meta"), "fetched 3m ago · the agent hasn't read this change");
  assert.equal(text(".ctx-pop-error"), "last refresh failed: exit 1: boom");
  assert.equal(text('[data-act="view"]'), "view text");
  assert.equal(el.querySelector(".ctx-pop-text").hidden, true);
  assert.equal(text('[data-act="detach"]'), "detach");
  const project = drawn(popoverTemplate(row({ scope: "project", kind: "push", hint: "not a url", has_text: false, fetched_at: null }), { now: NOW }));
  assert.equal(project.querySelector(".ctx-pop-kind").textContent, "project · pushed");
  assert.equal(project.querySelector("div.ctx-pop-hint").textContent, "not a url");
  assert.equal(project.querySelector('[data-act="detach"]').textContent, "mute here");
  assert.equal(project.querySelector('[data-act="view"]'), null);
  // The text read: shown, and no view button.
  const read = drawn(popoverTemplate(row(), { text: "the diff", now: NOW }));
  assert.equal(read.querySelector(".ctx-pop-text").hidden, false);
  assert.equal(read.querySelector(".ctx-pop-text").textContent, "the diff");
  assert.equal(read.querySelector('[data-act="view"]'), null);
});

test("chipsTemplate: a + URL chip last when a bundle's provider can attach one", () => {
  const el = drawn(chipsTemplate(chipModel([row()], NOW), { addUrl: true }));
  const add = el.lastElementChild;
  assert.deepEqual([add.className, add.dataset.act, add.textContent, add.getAttribute("aria-haspopup")],
                   ["ctx-chip ctx-add", "add", "+ URL", "dialog"]);
  assert.match(add.title, /Attach a URL/);
  assert.equal(drawn(chipsTemplate(chipModel([row()], NOW))).querySelector(".ctx-add"), null);
  assert.equal(drawn(chipsTemplate([], { addUrl: true })).querySelectorAll(".ctx-chip").length, 1);
  assert.match(markupOf(chipsTemplate([], { addUrl: true, addOpen: true })), /class="ctx-chip ctx-add open"/);
});

test("addFormTemplate: a URL field, an optional why, Attach; an error line when the last try failed", () => {
  const el = drawn(addFormTemplate());
  const form = el.querySelector("form.ctx-add-form");
  assert.equal(form.querySelector("strong").textContent, "Attach a URL");
  assert.equal(form.elements.url.type, "url");
  assert.equal(form.elements.url.required, true);
  assert.ok(form.elements.why);
  assert.equal(form.querySelector('button[type="submit"]').textContent, "Attach");
  assert.equal(form.querySelector('button[type="submit"]').disabled, false);
  assert.equal(form.querySelector(".ctx-pop-error"), null);
  const failed = drawn(addFormTemplate({ error: "no installed bundle resolves it", busy: true }));
  assert.equal(failed.querySelector(".ctx-pop-error").textContent, "no installed bundle resolves it");
  assert.equal(failed.querySelector(".ctx-pop-error").getAttribute("role"), "alert");
  assert.equal(failed.querySelector('button[type="submit"]').disabled, true);
});

// The chips on the shim's document: +el+ in the body, a stub api and
// window (no timers: the minute's tick is a spec's own call).
function chipsControl({ list, add = async () => ({ name: "pr-9" }), show = async () => ({ text: "the text" }) }) {
  const el = document.createElement("div");
  document.body.append(el);
  const toasts = [];
  const win = { innerWidth: 1000, innerHeight: 800, addEventListener() {}, setInterval() {}, confirm: () => true };
  const ctl = createContextChips({ el, api: { list, add, show, detach: async () => {} }, toast: (t) => toasts.push(t), win });
  const pop = document.getElementById("contextPopover");
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  return { ctl, el, pop, toasts, settle, done: () => { el.remove(); pop.remove(); } };
}

test("a failed attach keeps the form: the typed URL and why stay in the same fields, the URL has focus, Attach works again", async () => {
  let fail = true;
  const c = chipsControl({ list: async () => ({ sources: [], can_add_url: true }),
                           add: async () => { if (fail) throw new Error("no installed bundle resolves it (422)"); return { name: "pr-9" }; } });
  await c.ctl.load("s1");
  c.el.querySelector(".ctx-add").click();
  const form = c.pop.querySelector("form");
  const url = form.elements.url;
  const why = form.elements.why;
  same(document.activeElement, url, "focus");
  url.value = "https://x/1";
  why.value = "review it";
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await c.settle();
  assert.equal(c.pop.querySelector(".ctx-pop-error").textContent, "no installed bundle resolves it");
  same(c.pop.querySelector("form").elements.url, url, "url field");
  assert.equal(url.value, "https://x/1");
  same(c.pop.querySelector("form").elements.why, why, "why field");
  assert.equal(why.value, "review it");
  same(document.activeElement, url, "focus");
  assert.equal(c.pop.querySelector(".ctx-add-submit").disabled, false);
  assert.match(c.el.querySelector(".ctx-add").className, /\bopen\b/);
  fail = false;
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await c.settle();
  assert.equal(c.pop.hidden, true);
  assert.deepEqual(c.toasts, ["Attached pr-9: the agent gets a note before your next message"]);
  c.done();
});

test("a refresh redraws the chips in place: a focused chip keeps its node and focus, the open one stays marked", async () => {
  let sources = [row(), row({ name: "ci" })];
  const c = chipsControl({ list: async () => ({ sources, can_add_url: false }) });
  await c.ctl.load("s1");
  const chip = c.el.querySelector('[data-name="ci"]');
  chip.click();
  chip.focus();
  const meta = c.pop.querySelector(".ctx-pop-meta");
  sources = [row(), row({ name: "ci", unread: true })];
  await c.ctl.refresh();
  same(c.el.querySelector('[data-name="ci"]'), chip, "chip");
  same(document.activeElement, chip, "focus");
  assert.equal(chip.className, "ctx-chip unread open");
  // The open popover follows its row in the same nodes.
  same(c.pop.querySelector(".ctx-pop-meta"), meta, "meta line");
  assert.match(meta.textContent, /the agent hasn't read this change/);
  // A chip that went closes its popover.
  sources = [row()];
  await c.ctl.refresh();
  assert.equal(c.pop.hidden, true);
  assert.equal(c.el.querySelector(".open"), null);
  c.done();
});

test("view text shows the row's text in the popover; a refresh keeps it", async () => {
  const c = chipsControl({ list: async () => ({ sources: [row()] }) });
  await c.ctl.load("s1");
  c.el.querySelector('[data-name="pr-1"]').click();
  c.pop.querySelector('[data-act="view"]').click();
  await c.settle();
  const pre = c.pop.querySelector(".ctx-pop-text");
  assert.equal(pre.hidden, false);
  assert.equal(pre.textContent, "the text");
  assert.equal(c.pop.querySelector('[data-act="view"]'), null);
  await c.ctl.refresh();
  same(c.pop.querySelector(".ctx-pop-text"), pre, "text");
  assert.equal(pre.textContent, "the text");
  // Reopened, it starts without the text.
  c.ctl.close();
  c.el.querySelector('[data-name="pr-1"]').click();
  assert.equal(c.pop.querySelector(".ctx-pop-text").hidden, true);
  assert.ok(c.pop.querySelector('[data-act="view"]'));
  c.done();
});

test("a source inserted before the focused chip: the focus stays on the same source's chip", async () => {
  let sources = [row({ name: "b" })];
  const c = chipsControl({ list: async () => ({ sources, can_add_url: true }) });
  await c.ctl.load("s1");
  c.el.querySelector('[data-name="b"]').focus();
  sources = [row({ name: "a" }), row({ name: "b" })];
  await c.ctl.refresh();
  assert.equal(document.activeElement?.dataset?.name, "b");
  // Its source gone: no other chip takes the focus.
  sources = [row({ name: "a" })];
  await c.ctl.refresh();
  assert.notEqual(document.activeElement?.dataset?.name, "a");
  c.done();
});

test("the context popover and a session-bar chip's popover close each other", async () => {
  const { createChipPopover } = await import("../../../lib/samagotchi/web/public/chip_popover.js");
  const c = chipsControl({ list: async () => ({ sources: [row()], can_add_url: true }) });
  await c.ctl.load("s1");
  const bar = document.createElement("div");
  bar.innerHTML = '<button class="level-chip">thinking</button>';
  document.body.append(bar);
  const level = createChipPopover({
    id: "levelPop", className: "ctx-popover", width: 300, el: bar, anchor: ".level-chip",
    summary: () => ({}), win: { innerWidth: 1000, innerHeight: 800 }, show: () => {}, onSubmit: () => {},
  });
  c.el.querySelector(".ctx-add").click();
  assert.equal(c.pop.hidden, false);
  bar.querySelector(".level-chip").click();
  assert.equal(level.isOpen(), true);
  assert.equal(c.pop.hidden, true);
  c.el.querySelector(".ctx-add").click();
  assert.equal(c.pop.hidden, false);
  assert.equal(level.isOpen(), false);
  bar.remove();
  level.pop.remove();
  c.done();
});
