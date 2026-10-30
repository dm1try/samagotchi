import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { familyChipTemplate, familyRowsTemplate } from "../../../lib/samagotchi/web/public/families_view.js";
import { families } from "../../../lib/samagotchi/web/public/sessions_list.js";
import { html, render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

// A template's markup as the page gets it (lit's marker comments dropped).
const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};
const familyChipHtml = (f, opts) => markupOf(familyChipTemplate(f, opts));
const familyRowsHtml = (f, opts) => markupOf(familyRowsTemplate(f, opts));

const NOW = Date.parse("2026-10-06T12:00:00Z");
const del = (id, parent, extra = {}) => ({ id, short_id: id.slice(0, 8), parent_id: parent, delegate: true, status: "idle", updated_at: "2026-10-06T11:58:00Z", ...extra });
const family = (...members) => families([{ id: "p", short_id: "p" }, ...members])[0];

test("familyChipTemplate: a button with the count, live and waiting; its open state in aria-expanded", () => {
  const fam = family(del("c1", "p", { owner: "worker", status: "running" }), del("c2", "p", { pending_question: { id: "q" } }));
  const html = familyChipHtml(fam, { open: false });
  assert.match(html, /^<button type="button" class="family-chip waiting" aria-expanded="false"/);
  assert.match(html, /<span class="fc-arrow" aria-hidden="true">▸<\/span>2 delegates/);
  assert.match(html, /<span class="live-dot" aria-hidden="true"><\/span>1 live/);
  assert.match(html, /<span class="fc-waiting">1 waiting<\/span>/);
  assert.match(html, /title="2 delegates: 1 running · 1 waiting"/);
  assert.match(familyChipHtml(fam, { open: true }), /aria-expanded="true"/);
  const quiet = familyChipHtml(family(del("c1", "p")), { open: false });
  assert.match(quiet, /class="family-chip"/);
  assert.doesNotMatch(quiet, /live|fc-waiting/);
  assert.match(quiet, /1 delegate</);
  assert.equal(familyChipHtml({ head: { id: "x" }, members: [] }, { open: false }), "");
});

test("familyRowsTemplate: one row per member, indented by depth, escaped, with its dot, time and badges", () => {
  const fam = family(
    del("c1", "p", { first_preview: "<b>fix</b> it", owner: "worker", status: "running" }),
    del("g1", "c1", { first_preview: "grand", pending_question: { id: "q", kind: "approval", relayed_to: "c1" } }),
  );
  const html = familyRowsHtml(fam, { now: NOW });
  assert.match(html, /^<div class="family-rows" role="list">/);
  assert.equal((html.match(/class="family-row[ "]/g) || []).length, 2);
  assert.match(html, /data-id="c1" style="--depth:1"/);
  assert.match(html, /data-id="g1" style="--depth:2"/);
  assert.match(html, /&lt;b&gt;fix&lt;\/b&gt; it/);
  assert.doesNotMatch(html, /<b>fix/);
  assert.match(html, /status dot running/);
  assert.match(html, /status dot idle waiting/);
  assert.match(html, /2 min ago/);
  assert.match(html, /<span class="owner worker"/);
  // A relayed approval in its own parent's family: the plain kind.
  assert.match(html, /class="attn attn-approval"[^>]*>approval</);
  assert.doesNotMatch(html, /in parent/);
  // No archive buttons unless asked (the strip's popover, select mode).
  assert.doesNotMatch(html, /card-arch/);
});

test("familyRowsTemplate: active, match / dim (a search), archive buttons and the archived badge", () => {
  const fam = family(del("c1", "p"), del("c2", "p", { archived: true }));
  const html = familyRowsHtml(fam, { activeId: "c2", matchIds: new Set(["c1"]), archivable: true, now: NOW });
  assert.match(html, /class="family-row match" data-id="c1"/);
  assert.match(html, /class="family-row active dim archived" data-id="c2"/);
  assert.match(html, /<button type="button" class="card-arch" data-arch="c1" title="Archive: hide from the lists, keep for good" aria-label="Archive session c1"><\/button>/);
  assert.match(html, /data-arch="c2" title="Unarchive: back to the lists"/);
  assert.match(html, /<span class="archived-badge"[^>]*>archived<\/span>/);
  // No search: nothing marked.
  assert.doesNotMatch(familyRowsHtml(fam, { now: NOW }), /match|dim/);
});

// ── The strip's popover (createFamilyPop) on the shim's document ─────────
// Its element is a real one (lit draws the rows into it); the chips are
// fakes with the rect, card and attributes it reads.

import { createFamilyPop } from "../../../lib/samagotchi/web/public/families_view.js";

// The same node (assert.equal's message would inspect a whole DOM node).
const same = (actual, expected, what) => assert.ok(actual === expected, `${what}: not the same node`);

function fakeEl({ rect = null, card = null } = {}) {
  const attrs = new Map();
  return {
    focused: 0,
    isConnected: true,
    setAttribute: (k, v) => attrs.set(k, String(v)),
    getAttribute: (k) => attrs.get(k) ?? null,
    contains(other) { return other === this; },
    getBoundingClientRect: () => rect,
    closest: (sel) => (sel === ".card" ? card : null),
    focus() { this.focused += 1; },
  };
}

const rowsOf = (text) => html`<div class="family-rows">${text}</div>`;
const styleOf = (el) => ({ top: el.style.top, left: el.style.left, width: el.style.width });

function setupPop({ vw = 1440, rows = { p: rowsOf("rows p") }, id } = {}) {
  const body = document.createElement("div");
  document.body.append(body);
  // The shim's document's keys (the popover's Tab) and focus, its own body.
  const doc = { body, createElement: (tag) => document.createElement(tag), addEventListener: (...a) => document.addEventListener(...a),
                get activeElement() { return document.activeElement; } };
  const card = fakeEl({ rect: { left: 100, top: 20, bottom: 120, width: 360 } });
  const chips = { p: fakeEl({ rect: { left: 180, top: 90, bottom: 108, width: 120 }, card }), q: fakeEl({ rect: { left: 500, top: 90, bottom: 108, width: 120 }, card }) };
  const page = { picked: [], closes: 0, rows, chips };
  const pop = createFamilyPop({
    ...(id ? { id } : {}),
    doc, win: { innerWidth: vw },
    rowsFor: (id) => page.rows[id] ?? null,
    anchorFor: (id) => page.chips[id] ?? null,
    onPick: (id) => page.picked.push(id),
    onClose: () => { page.closes += 1; },
  });
  return { pop, page, body, el: () => body.firstElementChild };
}

test("familyPop opens under the chip, as wide as its card, in body; toggle closes it", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  assert.equal(pop.isOpen(), true);
  assert.equal(pop.openHead(), "p");
  assert.equal(el().id, "familyPop");
  assert.equal(el().hidden, false);
  assert.equal(el().textContent, "rows p");
  assert.deepEqual(styleOf(el()), { top: "114px", left: "100px", width: "360px" });
  assert.equal(page.chips.p.getAttribute("aria-expanded"), "true");
  pop.toggle("p");
  assert.equal(pop.isOpen(), false);
  assert.equal(el().hidden, true);
  assert.equal(page.chips.p.getAttribute("aria-expanded"), "false");
  assert.equal(page.closes, 1);
  // Another family's chip moves it there.
  pop.open("p");
  page.rows.q = rowsOf("rows q");
  pop.toggle("q");
  assert.equal(pop.openHead(), "q");
  assert.equal(el().textContent, "rows q");
  pop.close();
  assert.equal(el().textContent, "");
});

test("a second popover (a chain's) is an element of its own id", () => {
  const { pop, el } = setupPop({ id: "chainPop" });
  pop.open("p");
  assert.equal(el().id, "chainPop");
  assert.equal(el().className, "family-pop");
});

test("familyPop: Esc closes it (and stops there, the chip focused), other keys and a closed popover pass", () => {
  const { pop, page } = setupPop();
  const key = (k) => ({ key: k, stopped: 0, prevented: 0, stopImmediatePropagation() { this.stopped += 1; }, stopPropagation() { this.stopped += 1; }, preventDefault() { this.prevented += 1; } });
  const idle = key("Escape");
  assert.equal(pop.onKeydown(idle), false);
  assert.equal(idle.stopped, 0);
  pop.open("p");
  assert.equal(pop.onKeydown(key("Enter")), false);
  const esc = key("Escape");
  assert.equal(pop.onKeydown(esc), true);
  assert.ok(esc.stopped > 0);
  assert.equal(pop.isOpen(), false);
  assert.equal(page.chips.p.focused, 1);
});

test("familyPop is a modal dialog as every popover: Tab wraps in its rows, a Tab from outside goes in; focus in it goes back to the chip", () => {
  const { pop, page, el } = setupPop({ rows: { p: rowsOf(html`<button class="fr-open">a</button><button class="fr-open">b</button>`) } });
  const tab = (shiftKey = false) => {
    const e = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey, bubbles: true, cancelable: true });
    document.dispatchEvent(e);
    return e.defaultPrevented;
  };
  pop.open("p");
  assert.deepEqual([el().getAttribute("role"), el().getAttribute("aria-modal"), el().getAttribute("aria-label")], ["dialog", "true", "Delegates"]);
  const [a, b] = el().querySelectorAll(".fr-open");
  document.body.focus();
  assert.equal(tab(), true);
  same(document.activeElement, a, "a Tab from outside");
  assert.equal(tab(true), true);
  same(document.activeElement, b, "Shift+Tab before the first");
  assert.equal(tab(), true);
  same(document.activeElement, a, "Tab past the last");
  pop.onPointerDown({ target: document.createElement("div") });
  assert.equal(page.chips.p.focused, 1);
  assert.equal(tab(), false); // closed: the page's own Tab
  pop.open("p");
  pop.onPointerDown({ target: document.createElement("div") }); // the focus wasn't in it: stays where it is
  assert.equal(page.chips.p.focused, 1);
});

test("familyPop: a pointer down outside closes it; in the popover or on its chip it stays", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  pop.onPointerDown({ target: el().firstElementChild });
  assert.equal(pop.isOpen(), true);
  pop.onPointerDown({ target: page.chips.p });
  assert.equal(pop.isOpen(), true);
  pop.onPointerDown({ target: document.createElement("div") });
  assert.equal(pop.isOpen(), false);
});

test("familyPop: a row's click picks that session", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  page.rows.p = html`<div class="family-row" data-id="c1"><button class="fr-open">c1</button></div><p>no row</p>`;
  pop.refresh();
  el().querySelector(".fr-open").click();
  assert.deepEqual(page.picked, ["c1"]);
  el().querySelector("p").click();
  assert.deepEqual(page.picked, ["c1"]);
});

test("familyPop.refresh re-anchors to the redrawn chip, redraws the rows in place, closes when the family is gone", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  const rows = el().firstElementChild;
  // The strip drew again: a new chip element, the same rows.
  page.chips.p = fakeEl({ rect: { left: 40, top: 90, bottom: 130, width: 100 }, card: fakeEl({ rect: { left: 30, width: 320 } }) });
  pop.refresh();
  same(el().firstElementChild, rows, "rows");
  assert.deepEqual(styleOf(el()), { top: "136px", left: "30px", width: "320px" });
  assert.equal(page.chips.p.getAttribute("aria-expanded"), "true");
  page.rows.p = rowsOf("rows p, a new one");
  pop.refresh();
  same(el().firstElementChild, rows, "rows");
  assert.equal(el().textContent, "rows p, a new one");
  // Its card left the strip: closed.
  delete page.chips.p;
  pop.refresh();
  assert.equal(pop.isOpen(), false);
  // No members any more: closed.
  page.chips.p = fakeEl({ rect: { left: 0, top: 0, bottom: 10, width: 10 }, card: fakeEl({ rect: { left: 0, width: 300 } }) });
  pop.open("p");
  page.rows.p = null;
  pop.refresh();
  assert.equal(pop.isOpen(), false);
});

test("an open family popover drawn again with a row's status changed keeps that row's elements", () => {
  let fam = family(del("c1", "p", { status: "running", owner: "worker" }), del("c2", "p"));
  const { pop, page, el } = setupPop({ rows: {} });
  page.rows = { get p() { return familyRowsTemplate(fam, { now: NOW }); } };
  pop.open("p");
  const row = el().querySelector('.family-row[data-id="c1"]');
  const open = row.querySelector(".fr-open");
  open.focus();
  fam = family(del("c1", "p", { status: "idle" }), del("c2", "p"));
  pop.refresh();
  same(el().querySelector('.family-row[data-id="c1"]'), row, "row");
  same(row.querySelector(".fr-open"), open, "row button");
  same(document.activeElement, open, "focus");
  assert.match(row.querySelector(".status").className, /status dot idle/);
  assert.equal(row.querySelector(".owner"), null);
});

test("familyPop: never narrower than 300 px nor past the window's right edge", () => {
  const narrowCard = fakeEl({ rect: { left: 1300, width: 200 } });
  const { pop, page, el } = setupPop();
  page.chips.p = fakeEl({ rect: { left: 1320, top: 0, bottom: 20, width: 60 }, card: narrowCard });
  pop.open("p");
  assert.deepEqual(styleOf(el()), { top: "26px", left: "1132px", width: "300px" });
});

test("familyPop on a phone (600 px or less): the window's width minus 16 px gutters", () => {
  const { pop, el } = setupPop({ vw: 390 });
  pop.open("p");
  assert.deepEqual(styleOf(el()), { top: "114px", left: "16px", width: "358px" });
  const edge = setupPop({ vw: 600 });
  edge.pop.open("p");
  assert.equal(edge.el().style.width, "568px");
});

test("a member inserted before the focused row (a grandchild, depth first): the focus stays on the same session's row", () => {
  let fam = family(del("c1", "p"), del("c2", "p"));
  const { pop, page, el } = setupPop({ rows: {} });
  page.rows = { get p() { return familyRowsTemplate(fam, { now: NOW }); } };
  pop.open("p");
  el().querySelector('.family-row[data-id="c2"] .fr-open').focus();
  fam = family(del("c1", "p"), del("g1", "c1"), del("c2", "p"));
  pop.refresh();
  assert.deepEqual([...el().querySelectorAll(".family-row")].map((r) => r.dataset.id), ["c1", "g1", "c2"]);
  assert.equal(document.activeElement?.closest(".family-row")?.dataset.id, "c2");
  assert.equal(document.activeElement?.className, "fr-open");
  // Its session gone: no other row takes the focus.
  fam = family(del("c1", "p"), del("g1", "c1"));
  pop.refresh();
  assert.equal(document.activeElement?.closest?.(".family-row"), null);
});

// ── syncPulses: the dots' pulse on the timeline's clock ─────────────────────
import { syncPulses } from "../../../lib/samagotchi/web/public/families_view.js";

test("syncPulses puts every dot's animation on start time 0, leaves synced ones and dot-less nodes alone", () => {
  const sets = [];
  const anim = (startTime) => {
    let t = startTime;
    return { get startTime() { return t; }, set startTime(v) { sets.push(v); t = v; } };
  };
  const fresh = anim(null); // a pulse just started (a new node, a status flip)
  const late = anim(5230.5); // one started mid-way
  const synced = anim(0);
  const root = { querySelectorAll: (sel) => (sel === ".dot" ? [
    { getAnimations: () => [fresh, late] },
    { getAnimations: () => [synced] },
    { getAnimations: () => [] },
    {}, // no Web Animations (an old engine): nothing to do
  ] : []) };
  syncPulses(root);
  assert.equal(fresh.startTime, 0);
  assert.equal(late.startTime, 0);
  assert.deepEqual(sets, [0, 0]);
});

test("familyPop syncs its dots' pulse on every draw", () => {
  const dot = (cls) => html`<span class=${`status dot ${cls}`}></span>`;
  const { pop, page, el } = setupPop({ rows: { p: rowsOf(dot("waiting")) } });
  const seen = [];
  const orig = HTMLElement.prototype.getAnimations;
  HTMLElement.prototype.getAnimations = function () { seen.push(this.className); return []; };
  try {
    pop.open("p");
    page.rows.p = rowsOf(dot("running"));
    pop.refresh();
  } finally {
    if (orig) HTMLElement.prototype.getAnimations = orig;
    else delete HTMLElement.prototype.getAnimations;
  }
  assert.deepEqual(seen, ["status dot waiting", "status dot running"]);
  pop.close();
  assert.equal(el().textContent, "");
});
